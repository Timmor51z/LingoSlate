import ClassBridgeAudio
import ClassBridgeCore
import Darwin
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
    var evaluationStartSeconds: Double
    var evaluationEndSeconds: Double
    var audioDurationSeconds: Double
    var audioDecodeSeconds: Double
    var modelLoadSeconds: Double
    var inferenceSeconds: Double
    var realTimeSpeedup: Double
    var referenceSegmentCount: Int
    var hypothesisSegmentCount: Int
    var agreementWindowSeconds: Double
    var normalizationProfile: String
    var globalAgreementWordDistance: Int
    var globalAgreementWordErrorRate: Double
    var literalGlobalAgreementWordDistance: Int
    var literalGlobalAgreementWordErrorRate: Double
    var competitorAgreementWordErrors: WordErrorBreakdown?
    var competitorAgreementWordErrorRate: Double?
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
    case unsupportedAudioFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: swift run LecCueBenchmark "
                + "[--model eou120m|unified640|unified1120|unifiedOffline|nemotron1120] "
                + "[--audio raw|adaptive] [--start-seconds N] [--duration-seconds N] "
                + "<reference.json> <audio-file> <report.json>"
        case let .recognitionFailed(message):
            return "Recognition failed: \(message)"
        case let .unsupportedAudioFormat(fileExtension):
            return "Unsupported benchmark audio format '.\(fileExtension)'. "
                + "Convert input to 16 kHz mono PCM WAV first."
        }
    }
}

private enum BenchmarkModel: String {
    case eou120m
    case unified640
    case unified1120
    case unifiedOffline
    case nemotron1120

    var displayName: String {
        switch self {
        case .eou120m:
            return "FluidAudio Parakeet EOU 120M, 320 ms"
        case .unified640:
            return FluidAudioStreamingProfile.unified640ms.displayName
        case .unified1120:
            return FluidAudioStreamingProfile.unified1120ms.displayName
        case .unifiedOffline:
            return FluidAudioStreamingProfile.unifiedOffline15s.displayName
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
        case .unifiedOffline:
            return FluidAudioStreamingRecognitionEngine(profile: .unifiedOffline15s)
        case .nemotron1120:
            return FluidAudioStreamingRecognitionEngine(profile: .nemotron1120ms)
        }
    }

    var supportsTimestampWindows: Bool {
        self != .unifiedOffline
    }
}

private enum BenchmarkAudio: String {
    case raw
    case adaptive
}

private struct BenchmarkOptions {
    var model: BenchmarkModel = .eou120m
    var audio: BenchmarkAudio = .raw
    var startSeconds: Double = 0
    var durationSeconds: Double?
    var referenceURL: URL
    var audioURL: URL
    var reportURL: URL

    static func parse(_ arguments: [String]) throws -> BenchmarkOptions {
        var model = BenchmarkModel.eou120m
        var audio = BenchmarkAudio.raw
        var startSeconds = 0.0
        var durationSeconds: Double?
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
            case "--start-seconds":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index]), value >= 0 else {
                    throw BenchmarkError.invalidArguments
                }
                startSeconds = value
            case "--duration-seconds":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index]), value > 0 else {
                    throw BenchmarkError.invalidArguments
                }
                durationSeconds = value
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
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
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
    static func main() async {
        do {
            try await run()
        } catch {
            let message = "LecCueBenchmark: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let options = try BenchmarkOptions.parse(Array(CommandLine.arguments.dropFirst()))
        let decoder = JSONDecoder()
        let reference = try decoder.decode(
            LecSyncReference.self,
            from: Data(contentsOf: options.referenceURL)
        )

        let supportedAudioExtensions: Set<String> = [
            "wav", "wave", "caf", "aif", "aiff",
        ]
        let audioExtension = options.audioURL.pathExtension.lowercased()
        guard supportedAudioExtensions.contains(audioExtension) else {
            throw BenchmarkError.unsupportedAudioFormat(audioExtension)
        }

        let decodeStartedAt = Date()
        let allSamples = try AudioConverter().resampleAudioFile(options.audioURL)
        let audioDecodeSeconds = Date().timeIntervalSince(decodeStartedAt)
        let sampleRate = 16_000.0
        let fullAudioDurationSeconds = Double(allSamples.count) / sampleRate
        guard options.startSeconds < fullAudioDurationSeconds else {
            throw BenchmarkError.invalidArguments
        }
        let startSample = min(
            allSamples.count,
            Int((options.startSeconds * sampleRate).rounded(.down))
        )
        let requestedEndSeconds = options.durationSeconds.map {
            options.startSeconds + $0
        } ?? fullAudioDurationSeconds
        let endSample = min(
            allSamples.count,
            Int((requestedEndSeconds * sampleRate).rounded(.up))
        )
        let samples = Array(allSamples[startSample..<max(startSample, endSample)])
        let evaluationStartSeconds = Double(startSample) / sampleRate
        let audioDurationSeconds = Double(samples.count) / sampleRate
        let evaluationEndSeconds = evaluationStartSeconds + audioDurationSeconds
        let selectedReferenceSegments = reference.segments.filter { segment in
            let midpoint = (segment.startMs + segment.endMs) / 2_000
            return midpoint >= evaluationStartSeconds && midpoint < evaluationEndSeconds
        }

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
        let hypothesisSegments = (try await collector.result()).map { segment in
            HypothesisSegment(
                text: segment.text,
                startSeconds: segment.startSeconds + evaluationStartSeconds,
                endSeconds: segment.endSeconds + evaluationStartSeconds
            )
        }
        let referenceText = selectedReferenceSegments.map(\.text).joined(separator: " ")
        let hypothesisText = hypothesisSegments.map(\.text).joined(separator: " ")
        let globalDistance = TranscriptComparison.evaluationWordEditDistance(
            reference: referenceText,
            hypothesis: hypothesisText
        )
        let referenceWordCount = TranscriptComparison.evaluationWords(in: referenceText).count
        let globalErrorRate = referenceWordCount > 0
            ? Double(globalDistance) / Double(referenceWordCount)
            : (hypothesisText.isEmpty ? 0 : 1)
        let literalGlobalDistance = TranscriptComparison.wordEditDistance(
            reference: referenceText,
            hypothesis: hypothesisText
        )
        let literalReferenceWordCount = TranscriptComparison.normalizedWords(
            in: referenceText
        ).count
        let literalGlobalErrorRate = literalReferenceWordCount > 0
            ? Double(literalGlobalDistance) / Double(literalReferenceWordCount)
            : (hypothesisText.isEmpty ? 0 : 1)
        let windows = options.model.supportsTimestampWindows
            ? makeWindowReports(
                reference: selectedReferenceSegments,
                hypothesis: hypothesisSegments,
                startSeconds: evaluationStartSeconds,
                endSeconds: evaluationEndSeconds
            )
            : []
        let aggregateErrors = options.model.supportsTimestampWindows
            ? windows.reduce(WordErrorBreakdown()) { partial, window in
                partial.adding(window.wordErrors)
            }
            : nil
        let numberRecall = TranscriptComparison.tokenRecall(
            referenceTokens: TranscriptComparison.evaluationNumberTokens(in: referenceText),
            hypothesisTokens: TranscriptComparison.evaluationNumberTokens(in: hypothesisText)
        )
        let acronymRecall = TranscriptComparison.tokenRecall(
            referenceTokens: TranscriptComparison.acronymTokens(in: referenceText),
            hypothesisTokens: TranscriptComparison.evaluationWords(in: hypothesisText)
        )
        let normalizedWordCoverage = TranscriptComparison.wordCoverage(
            reference: referenceText,
            hypothesis: hypothesisText
        )

        let report = BenchmarkReport(
            schemaVersion: 6,
            generatedAt: Date(),
            referenceKind: "LecSync competitor output; not manually corrected ground truth",
            referenceSession: reference.session,
            model: options.model.displayName,
            audioEnhancement: options.audio.rawValue,
            evaluationStartSeconds: evaluationStartSeconds,
            evaluationEndSeconds: evaluationEndSeconds,
            audioDurationSeconds: audioDurationSeconds,
            audioDecodeSeconds: audioDecodeSeconds,
            modelLoadSeconds: modelLoadSeconds,
            inferenceSeconds: inferenceSeconds,
            realTimeSpeedup: audioDurationSeconds / max(inferenceSeconds, 0.001),
            referenceSegmentCount: selectedReferenceSegments.count,
            hypothesisSegmentCount: hypothesisSegments.count,
            agreementWindowSeconds: 300,
            normalizationProfile: "case-folded alphanumeric words; contractions, "
                + "dotted acronyms, and whole-hour times canonicalized",
            globalAgreementWordDistance: globalDistance,
            globalAgreementWordErrorRate: globalErrorRate,
            literalGlobalAgreementWordDistance: literalGlobalDistance,
            literalGlobalAgreementWordErrorRate: literalGlobalErrorRate,
            competitorAgreementWordErrors: aggregateErrors,
            competitorAgreementWordErrorRate: aggregateErrors?.errorRate,
            normalizedWordCoverage: normalizedWordCoverage,
            numberRecall: numberRecall,
            acronymRecall: acronymRecall,
            windows: windows,
            hypothesisSegments: hypothesisSegments,
            translationComparisonStatus: "Not run: LecCue local Chinese translation is not integrated yet",
            caveats: [
                "LecSync text is a competitor baseline, not ground truth.",
                "The report covers audio from \(evaluationStartSeconds) to \(evaluationEndSeconds) seconds.",
                "Word errors are aggregated in five-minute timestamp windows to reduce segment-boundary penalties.",
                "Global agreement follows transcript word order and is the primary model-comparison metric.",
                "Primary global agreement removes formatting-only differences in "
                    + "contractions, dotted acronyms, and whole-hour times; literal "
                    + "global agreement is retained separately.",
                "Timestamp-window diagnostics are omitted for offline transcripts without segment timestamps.",
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
            format: "Global LecSync agreement word error rate: %.2f%%",
            globalErrorRate * 100
        ))
        print(String(format: "Local inference speed: %.2fx realtime", report.realTimeSpeedup))
        print("Model: \(options.model.displayName)")
        print("Audio enhancement: \(options.audio.rawValue)")
        print(String(
            format: "Evaluation range: %.2f-%.2f seconds",
            evaluationStartSeconds,
            evaluationEndSeconds
        ))
        print("Report: \(options.reportURL.path)")
    }

    private static func makeWindowReports(
        reference: [ReferenceSegment],
        hypothesis: [HypothesisSegment],
        startSeconds: Double,
        endSeconds: Double
    ) -> [WindowReport] {
        let windowSize = 300.0
        let durationSeconds = max(0, endSeconds - startSeconds)
        let windowCount = max(1, Int(ceil(durationSeconds / windowSize)))

        return (0..<windowCount).map { index in
            let start = startSeconds + Double(index) * windowSize
            let end = min(start + windowSize, endSeconds)
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
