import ClassBridgeAudio
import ClassBridgeCore
import FluidAudio
import Foundation

private struct LecSyncReference: Decodable {
    var schemaVersion: Int
    var session: ReferenceSession
    var segments: [ReferenceSegment]
}

private struct ReferenceSession: Codable {
    var id: String
    var title: String?
    var sourceLanguage: String
    var targetLanguage: String
    var durationSeconds: Double
    var segmentCount: Int
}

private struct ReferenceSegment: Decodable {
    var index: Int
    var speaker: String?
    var text: String
    var translatedText: String?
    var startMs: Double
    var endMs: Double
    var confidence: Double?
}

private struct HypothesisSegment: Codable, Sendable {
    var text: String
    var startSeconds: Double
    var endSeconds: Double
}

private struct WindowReport: Codable {
    var startSeconds: Double
    var endSeconds: Double
    var wordErrors: WordErrorBreakdown
    var wordErrorRate: Double
}

private struct BenchmarkReport: Codable {
    var schemaVersion: Int
    var generatedAt: Date
    var referenceKind: String
    var referenceSession: ReferenceSession
    var model: String
    var audioEnhancement: String
    var audioDurationSeconds: Double
    var audioDecodeSeconds: Double
    var modelLoadSeconds: Double
    var inferenceSeconds: Double
    var realTimeSpeedup: Double
    var referenceSegmentCount: Int
    var hypothesisSegmentCount: Int
    var agreementWindowSeconds: Double
    var competitorAgreementWordErrors: WordErrorBreakdown
    var competitorAgreementWordErrorRate: Double
    var normalizedWordCoverage: WordCoverageMetrics
    var numberRecall: TokenRecallMetrics
    var acronymRecall: TokenRecallMetrics
    var windows: [WindowReport]
    var hypothesisSegments: [HypothesisSegment]
    var translationComparisonStatus: String
    var caveats: [String]
}

private enum BenchmarkError: LocalizedError {
    case invalidArguments
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: swift run LecCueBenchmark [--model eou120m|unified640|unified1120|nemotron1120] [--audio raw|adaptive] <reference.json> <audio-file> <report.json>"
        case let .recognitionFailed(message):
            return "Recognition failed: \(message)"
        }
    }
}

private enum BenchmarkModel: String {
    case eou120m
    case unified640
    case unified1120
    case nemotron1120

    var displayName: String {
        switch self {
        case .eou120m:
            return "FluidAudio Parakeet EOU 120M, 320 ms"
        case .unified640:
            return FluidAudioStreamingProfile.unified640ms.displayName
        case .unified1120:
            return FluidAudioStreamingProfile.unified1120ms.displayName
        case .nemotron1120:
            return FluidAudioStreamingProfile.nemotron1120ms.displayName
        }
    }

    func makeEngine() -> any SpeechRecognitionEngine {
        switch self {
        case .eou120m:
            return FluidAudioRecognitionEngine()
        case .unified640:
            return FluidAudioStreamingRecognitionEngine(profile: .unified640ms)
        case .unified1120:
            return FluidAudioStreamingRecognitionEngine(profile: .unified1120ms)
        case .nemotron1120:
            return FluidAudioStreamingRecognitionEngine(profile: .nemotron1120ms)
        }
    }
}

private enum BenchmarkAudio: String {
    case raw
    case adaptive
}

private struct BenchmarkOptions {
    var model: BenchmarkModel = .eou120m
    var audio: BenchmarkAudio = .raw
    var referenceURL: URL
    var audioURL: URL
    var reportURL: URL

    static func parse(_ arguments: [String]) throws -> BenchmarkOptions {
        var model = BenchmarkModel.eou120m
        var audio = BenchmarkAudio.raw
        var paths: [String] = []
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--model":
                index += 1
                guard index < arguments.count,
                      let value = BenchmarkModel(rawValue: arguments[index]) else {
                    throw BenchmarkError.invalidArguments
                }
                model = value
            case "--audio":
                index += 1
                guard index < arguments.count,
                      let value = BenchmarkAudio(rawValue: arguments[index]) else {
                    throw BenchmarkError.invalidArguments
                }
                audio = value
            default:
                paths.append(arguments[index])
            }
            index += 1
        }

        guard paths.count == 3 else {
            throw BenchmarkError.invalidArguments
        }
        return BenchmarkOptions(
            model: model,
            audio: audio,
            referenceURL: URL(fileURLWithPath: paths[0]),
            audioURL: URL(fileURLWithPath: paths[1]),
            reportURL: URL(fileURLWithPath: paths[2])
        )
    }
}

private actor RecognitionCollector {
    private var segments: [HypothesisSegment] = []
    private var failureMessage: String?

    func consume(_ event: RecognitionEvent) {
        switch event {
        case let .final(_, text, startTime, endTime, _, _):
            segments.append(
                HypothesisSegment(
                    text: text,
                    startSeconds: startTime,
                    endSeconds: endTime
                )
            )
        case let .failed(message):
            failureMessage = message
        default:
            break
        }
    }

    func result() throws -> [HypothesisSegment] {
        if let failureMessage {
            throw BenchmarkError.recognitionFailed(failureMessage)
        }
        return segments
    }
}

@main
private struct LecCueBenchmark {
    static func main() async throws {
        let options = try BenchmarkOptions.parse(Array(CommandLine.arguments.dropFirst()))
        let decoder = JSONDecoder()
        let reference = try decoder.decode(
            LecSyncReference.self,
            from: Data(contentsOf: options.referenceURL)
        )

        let decodeStartedAt = Date()
        let samples = try AudioConverter().resampleAudioFile(options.audioURL)
        let audioDecodeSeconds = Date().timeIntervalSince(decodeStartedAt)
        let sampleRate = 16_000.0
        let audioDurationSeconds = Double(samples.count) / sampleRate

        let baseEngine = options.model.makeEngine()
        let engine: any SpeechRecognitionEngine = options.audio == .adaptive
            ? AudioEnhancingRecognitionEngine(base: baseEngine)
            : baseEngine
        let collector = RecognitionCollector()
        let eventTask = Task {
            for await event in engine.events {
                await collector.consume(event)
            }
        }

        let modelStartedAt = Date()
        try await engine.start(
            configuration: RecognitionConfiguration(
                course: Course(name: reference.session.title ?? "LecSync benchmark")
            )
        )
        let modelLoadSeconds = Date().timeIntervalSince(modelStartedAt)

        let inferenceStartedAt = Date()
        let frameSize = 3_200
        let progressInterval = Int(sampleRate * 300)
        var nextProgressOffset = progressInterval
        var offset = 0

        do {
            while offset < samples.count {
                let end = min(offset + frameSize, samples.count)
                try await engine.accept(
                    AudioFrame(
                        samples: Array(samples[offset..<end]),
                        sampleRate: sampleRate,
                        capturedAt: Double(offset) / sampleRate
                    )
                )
                offset = end

                if offset >= nextProgressOffset {
                    print("Processed \(Int(Double(offset) / sampleRate)) audio seconds")
                    nextProgressOffset += progressInterval
                }
            }
            try await engine.finalize()
        } catch {
            eventTask.cancel()
            throw error
        }

        await eventTask.value
        let inferenceSeconds = Date().timeIntervalSince(inferenceStartedAt)
        let hypothesisSegments = try await collector.result()
        let windows = makeWindowReports(
            reference: reference.segments,
            hypothesis: hypothesisSegments,
            durationSeconds: max(reference.session.durationSeconds, audioDurationSeconds)
        )
        let aggregateErrors = windows.reduce(WordErrorBreakdown()) { partial, window in
            partial.adding(window.wordErrors)
        }

        let referenceText = reference.segments.map(\.text).joined(separator: " ")
        let hypothesisText = hypothesisSegments.map(\.text).joined(separator: " ")
        let numberRecall = TranscriptComparison.tokenRecall(
            referenceTokens: TranscriptComparison.numberTokens(in: referenceText),
            hypothesisTokens: TranscriptComparison.numberTokens(in: hypothesisText)
        )
        let acronymRecall = TranscriptComparison.tokenRecall(
            referenceTokens: TranscriptComparison.acronymTokens(in: referenceText),
            hypothesisTokens: TranscriptComparison.normalizedWords(in: hypothesisText)
        )
        let normalizedWordCoverage = TranscriptComparison.wordCoverage(
            reference: referenceText,
            hypothesis: hypothesisText
        )

        let report = BenchmarkReport(
            schemaVersion: 3,
            generatedAt: Date(),
            referenceKind: "LecSync competitor output; not manually corrected ground truth",
            referenceSession: reference.session,
            model: options.model.displayName,
            audioEnhancement: options.audio.rawValue,
            audioDurationSeconds: audioDurationSeconds,
            audioDecodeSeconds: audioDecodeSeconds,
            modelLoadSeconds: modelLoadSeconds,
            inferenceSeconds: inferenceSeconds,
            realTimeSpeedup: audioDurationSeconds / max(inferenceSeconds, 0.001),
            referenceSegmentCount: reference.segments.count,
            hypothesisSegmentCount: hypothesisSegments.count,
            agreementWindowSeconds: 300,
            competitorAgreementWordErrors: aggregateErrors,
            competitorAgreementWordErrorRate: aggregateErrors.errorRate,
            normalizedWordCoverage: normalizedWordCoverage,
            numberRecall: numberRecall,
            acronymRecall: acronymRecall,
            windows: windows,
            hypothesisSegments: hypothesisSegments,
            translationComparisonStatus: "Not run: LecCue local Chinese translation is not integrated yet",
            caveats: [
                "LecSync text is a competitor baseline, not ground truth.",
                "Word errors are aggregated in five-minute timestamp windows to reduce segment-boundary penalties.",
                "Word coverage ignores ordering and timestamps; it measures shared vocabulary, not transcription accuracy.",
                "Number recall compares written forms, so spoken-number versus digit formatting requires inverse text normalization before interpretation.",
                "Speaker diarization and Chinese translation are not evaluated in this report.",
            ]
        )

        try FileManager.default.createDirectory(
            at: options.reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: options.reportURL, options: .atomic)

        print(String(
            format: "LecSync agreement word error rate: %.2f%%",
            aggregateErrors.errorRate * 100
        ))
        print(String(format: "Local inference speed: %.2fx realtime", report.realTimeSpeedup))
        print("Model: \(options.model.displayName)")
        print("Audio enhancement: \(options.audio.rawValue)")
        print("Report: \(options.reportURL.path)")
    }

    private static func makeWindowReports(
        reference: [ReferenceSegment],
        hypothesis: [HypothesisSegment],
        durationSeconds: Double
    ) -> [WindowReport] {
        let windowSize = 300.0
        let windowCount = max(1, Int(ceil(durationSeconds / windowSize)))

        return (0..<windowCount).map { index in
            let start = Double(index) * windowSize
            let end = min(start + windowSize, durationSeconds)
            let referenceText = reference
                .filter { segment in
                    let midpoint = (segment.startMs + segment.endMs) / 2_000
                    return midpoint >= start && midpoint < end
                }
                .map(\.text)
                .joined(separator: " ")
            let hypothesisText = hypothesis
                .filter { segment in
                    let midpoint = (segment.startSeconds + segment.endSeconds) / 2
                    return midpoint >= start && midpoint < end
                }
                .map(\.text)
                .joined(separator: " ")

            let wordErrors = TranscriptComparison.wordErrors(
                reference: referenceText,
                hypothesis: hypothesisText
            )
            return WindowReport(
                startSeconds: start,
                endSeconds: end,
                wordErrors: wordErrors,
                wordErrorRate: wordErrors.errorRate
            )
        }
    }
}
