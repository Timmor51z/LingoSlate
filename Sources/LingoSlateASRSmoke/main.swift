import LingoSlateAudio
import LingoSlateCore
import LingoSlateSoniox
import Darwin
import FluidAudio
import Foundation

private enum SmokeError: LocalizedError {
    case invalidArguments
    case missingSonioxAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: swift run LingoSlateASRSmoke [--soniox] "
                + "[--translate LANGUAGE] [--start-seconds N] "
                + "[--duration-seconds N] [--course NAME] [--term TERM] "
                + "[--glossary SOURCE=TARGET] [--show-partials] <audio-file>"
        case .missingSonioxAPIKey:
            return "Set SONIOX_API_KEY before running with --soniox"
        }
    }
}

private struct SmokeOptions {
    var usesSoniox = false
    var translationTargetLanguage: String?
    var startSeconds = 0.0
    var durationSeconds: Double?
    var courseName = "LingoSlate ASR smoke test"
    var terms: [String] = []
    var glossaryTerms: [GlossaryTerm] = []
    var showsPartials = false
    var audioURL: URL

    static func parse(_ arguments: [String]) throws -> SmokeOptions {
        var usesSoniox = false
        var translationTargetLanguage: String?
        var startSeconds = 0.0
        var durationSeconds: Double?
        var courseName = "LingoSlate ASR smoke test"
        var terms: [String] = []
        var glossaryTerms: [GlossaryTerm] = []
        var showsPartials = false
        var path: String?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--soniox":
                usesSoniox = true
            case "--translate":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw SmokeError.invalidArguments
                }
                translationTargetLanguage = arguments[index]
            case "--start-seconds":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index]), value >= 0 else {
                    throw SmokeError.invalidArguments
                }
                startSeconds = value
            case "--duration-seconds":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index]), value > 0 else {
                    throw SmokeError.invalidArguments
                }
                durationSeconds = value
            case "--course":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw SmokeError.invalidArguments
                }
                courseName = arguments[index]
            case "--term":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw SmokeError.invalidArguments
                }
                terms.append(arguments[index])
            case "--glossary":
                index += 1
                guard index < arguments.count else { throw SmokeError.invalidArguments }
                let pair = arguments[index].split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else {
                    throw SmokeError.invalidArguments
                }
                glossaryTerms.append(
                    GlossaryTerm(
                        source: pair[0],
                        target: pair[1],
                        origin: .user,
                        isApproved: true
                    )
                )
            case "--show-partials":
                showsPartials = true
            default:
                guard path == nil else { throw SmokeError.invalidArguments }
                path = arguments[index]
            }
            index += 1
        }

        guard let path, translationTargetLanguage == nil || usesSoniox else {
            throw SmokeError.invalidArguments
        }
        return SmokeOptions(
            usesSoniox: usesSoniox,
            translationTargetLanguage: translationTargetLanguage,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            courseName: courseName,
            terms: terms,
            glossaryTerms: glossaryTerms,
            showsPartials: showsPartials,
            audioURL: URL(fileURLWithPath: path)
        )
    }
}

@main
struct LingoSlateASRSmoke {
    static func main() async throws {
        let options = try SmokeOptions.parse(Array(CommandLine.arguments.dropFirst()))
        let allSamples = try AudioConverter().resampleAudioFile(options.audioURL)
        let sampleRate = 16_000.0
        let startSample = min(allSamples.count, Int(options.startSeconds * sampleRate))
        let endSample = min(
            allSamples.count,
            options.durationSeconds.map { startSample + Int($0 * sampleRate) }
                ?? allSamples.count
        )
        guard startSample < endSample else { throw SmokeError.invalidArguments }
        let samples = Array(allSamples[startSample..<endSample])

        let engine: any SpeechRecognitionEngine
        if options.usesSoniox {
            guard let apiKey = ProcessInfo.processInfo.environment["SONIOX_API_KEY"],
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SmokeError.missingSonioxAPIKey
            }
            engine = SonioxRecognitionEngine(apiKey: apiKey)
        } else {
            engine = FluidAudioRecognitionEngine()
        }

        let eventTask = Task {
            for await event in engine.events {
                switch event {
                case .started:
                    print("ASR ready")
                case let .provisional(_, text, _, _, _):
                    if options.showsPartials { print("PARTIAL: \(text)") }
                case let .final(_, text, startTime, endTime, _, _):
                    print(String(format: "FINAL %.2f-%.2f: %@", startTime, endTime, text))
                case let .bilingualProvisional(result):
                    if options.showsPartials, let translation = result.translatedText {
                        print("PARTIAL: \(result.sourceText) | \(translation)")
                    }
                case let .bilingualFinal(result):
                    print(
                        String(
                            format: "FINAL %.2f-%.2f [%@]: %@ | %@",
                            result.startTime,
                            result.endTime,
                            result.sourceLanguage ?? "unknown",
                            result.sourceText,
                            result.translatedText ?? ""
                        )
                    )
                case let .failed(message):
                    print("FAILED: \(message)")
                case .finished:
                    print("ASR finished")
                }
            }
        }

        try await engine.start(
            configuration: RecognitionConfiguration(
                course: Course(
                    name: options.courseName,
                    recognitionTerms: options.terms
                ),
                approvedTerms: options.glossaryTerms,
                translationTargetLanguage: options.translationTargetLanguage
            )
        )

        let frameSize = 3_200
        let clock = ContinuousClock()
        let streamingStartedAt = clock.now
        var offset = 0
        while offset < samples.count {
            if options.usesSoniox {
                try await clock.sleep(
                    until: streamingStartedAt.advanced(
                        by: .seconds(Double(offset) / sampleRate)
                    )
                )
            }
            let end = min(offset + frameSize, samples.count)
            try await engine.accept(
                AudioFrame(
                    samples: Array(samples[offset..<end]),
                    sampleRate: sampleRate,
                    capturedAt: Double(offset) / sampleRate
                )
            )
            offset = end
        }

        try await engine.finalize()
        await eventTask.value
    }
}
