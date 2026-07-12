import LingoSlateCore
import Darwin
import Foundation

private struct LecSyncReference: Decodable {
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
    var text: String
    var startMs: Double
    var endMs: Double
}

private struct WhisperResult: Decodable {
    var text: String
    var segments: [WhisperSegment]
}

private struct WhisperSegment: Decodable {
    var start: Double
    var end: Double
    var text: String
}

private struct HypothesisSegment: Codable {
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}

private struct ExternalTranscriptReport: Codable {
    var schemaVersion = 1
    var generatedAt: Date
    var referenceKind: String
    var referenceSession: ReferenceSession
    var hypothesisKind: String
    var evaluationStartSeconds: Double
    var evaluationEndSeconds: Double
    var referenceSegmentCount: Int
    var hypothesisSegmentCount: Int
    var normalizationProfile: String
    var globalAgreementWordDistance: Int
    var globalAgreementWordErrorRate: Double
    var literalGlobalAgreementWordDistance: Int
    var literalGlobalAgreementWordErrorRate: Double
    var wordErrors: WordErrorBreakdown
    var normalizedWordCoverage: WordCoverageMetrics
    var numberRecall: TokenRecallMetrics
    var acronymRecall: TokenRecallMetrics
    var hypothesisSegments: [HypothesisSegment]
    var caveats: [String]
}

private struct Options {
    var startSeconds = 0.0
    var durationSeconds: Double?
    var label = "External transcript"
    var referenceURL: URL
    var whisperURL: URL
    var reportURL: URL

    static func parse(_ arguments: [String]) throws -> Options {
        var startSeconds = 0.0
        var durationSeconds: Double?
        var label = "External transcript"
        var paths: [String] = []
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
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
            case "--label":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw BenchmarkError.invalidArguments
                }
                label = arguments[index]
            default:
                paths.append(arguments[index])
            }
            index += 1
        }

        guard paths.count == 3 else {
            throw BenchmarkError.invalidArguments
        }
        return Options(
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            label: label,
            referenceURL: URL(fileURLWithPath: paths[0]),
            whisperURL: URL(fileURLWithPath: paths[1]),
            reportURL: URL(fileURLWithPath: paths[2])
        )
    }
}

private enum BenchmarkError: LocalizedError {
    case invalidArguments
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: swift run LingoSlateTranscriptBenchmark [--start-seconds N] "
                + "[--duration-seconds N] "
                + "[--label NAME] <reference.json> <whisper.json> <report.json>"
        case .emptyTranscript:
            return "The external transcript contains no text"
        }
    }
}

@main
private struct LingoSlateTranscriptBenchmark {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(
                Data("LingoSlateTranscriptBenchmark: \(error.localizedDescription)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        let decoder = JSONDecoder()
        let reference = try decoder.decode(
            LecSyncReference.self,
            from: Data(contentsOf: options.referenceURL)
        )
        let rawWhisperData = try Data(contentsOf: options.whisperURL)
        let whisperData = sanitizingBareNonFiniteNumbers(in: rawWhisperData)
        let whisper = try decoder.decode(
            WhisperResult.self,
            from: whisperData
        )
        let relativeEndSeconds = whisper.segments.map(\.end).max() ?? 0
        let requestedEndSeconds = options.durationSeconds.map {
            options.startSeconds + $0
        } ?? (options.startSeconds + relativeEndSeconds)
        guard options.startSeconds < reference.session.durationSeconds,
              requestedEndSeconds > options.startSeconds else {
            throw BenchmarkError.invalidArguments
        }
        let evaluationEndSeconds = min(
            reference.session.durationSeconds,
            requestedEndSeconds
        )
        let evaluationDurationSeconds = evaluationEndSeconds - options.startSeconds
        let selectedWhisperSegments = whisper.segments.filter { segment in
            let midpoint = (segment.start + segment.end) / 2
            return midpoint >= 0 && midpoint < evaluationDurationSeconds
        }
        let hypothesisText = selectedWhisperSegments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hypothesisText.isEmpty else {
            throw BenchmarkError.emptyTranscript
        }
        let selectedReferenceSegments = reference.segments.filter { segment in
            let midpoint = (segment.startMs + segment.endMs) / 2_000
            return midpoint >= options.startSeconds && midpoint < evaluationEndSeconds
        }
        let referenceText = selectedReferenceSegments.map(\.text).joined(separator: " ")
        let referenceWordCount = TranscriptComparison.evaluationWords(in: referenceText).count
        let globalDistance = TranscriptComparison.evaluationWordEditDistance(
            reference: referenceText,
            hypothesis: hypothesisText
        )
        let literalDistance = TranscriptComparison.wordEditDistance(
            reference: referenceText,
            hypothesis: hypothesisText
        )
        let literalReferenceCount = TranscriptComparison.normalizedWords(in: referenceText).count
        let hypothesisSegments = selectedWhisperSegments.map { segment in
            HypothesisSegment(
                startSeconds: segment.start + options.startSeconds,
                endSeconds: segment.end + options.startSeconds,
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        var caveats = [
            "LecSync text is a competitor baseline, not ground truth.",
            "The report covers source audio from \(options.startSeconds) to "
                + "\(evaluationEndSeconds) seconds.",
            "Inference time and energy use are not included in imported transcript reports.",
        ]
        if whisperData != rawWhisperData {
            caveats.append(
                "Bare NaN or Infinity values in unused external diagnostic fields were decoded as null."
            )
        }

        let report = ExternalTranscriptReport(
            generatedAt: Date(),
            referenceKind: "LecSync competitor output; not manually corrected ground truth",
            referenceSession: reference.session,
            hypothesisKind: options.label,
            evaluationStartSeconds: options.startSeconds,
            evaluationEndSeconds: evaluationEndSeconds,
            referenceSegmentCount: selectedReferenceSegments.count,
            hypothesisSegmentCount: hypothesisSegments.count,
            normalizationProfile: "case-folded alphanumeric words; contractions, "
                + "dotted acronyms, and whole-hour times canonicalized",
            globalAgreementWordDistance: globalDistance,
            globalAgreementWordErrorRate: referenceWordCount > 0
                ? Double(globalDistance) / Double(referenceWordCount)
                : 1,
            literalGlobalAgreementWordDistance: literalDistance,
            literalGlobalAgreementWordErrorRate: literalReferenceCount > 0
                ? Double(literalDistance) / Double(literalReferenceCount)
                : 1,
            wordErrors: TranscriptComparison.wordErrors(
                reference: referenceText,
                hypothesis: hypothesisText
            ),
            normalizedWordCoverage: TranscriptComparison.wordCoverage(
                reference: referenceText,
                hypothesis: hypothesisText
            ),
            numberRecall: TranscriptComparison.tokenRecall(
                referenceTokens: TranscriptComparison.evaluationNumberTokens(in: referenceText),
                hypothesisTokens: TranscriptComparison.evaluationNumberTokens(in: hypothesisText)
            ),
            acronymRecall: TranscriptComparison.tokenRecall(
                referenceTokens: TranscriptComparison.acronymTokens(in: referenceText),
                hypothesisTokens: TranscriptComparison.evaluationWords(in: hypothesisText)
            ),
            hypothesisSegments: hypothesisSegments,
            caveats: caveats
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
            report.globalAgreementWordErrorRate * 100
        ))
        print("Hypothesis: \(report.hypothesisKind)")
        print(String(
            format: "Evaluation range: %.2f-%.2f seconds",
            report.evaluationStartSeconds,
            report.evaluationEndSeconds
        ))
        print("Report: \(options.reportURL.path)")
    }

    private static func sanitizingBareNonFiniteNumbers(in data: Data) -> Data {
        let bytes = [UInt8](data)
        let replacements: [([UInt8], [UInt8])] = [
            (Array("-Infinity".utf8), Array("null".utf8)),
            (Array("Infinity".utf8), Array("null".utf8)),
            (Array("NaN".utf8), Array("null".utf8)),
        ]
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var isInsideString = false
        var isEscaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if isInsideString {
                output.append(byte)
                if isEscaped {
                    isEscaped = false
                } else if byte == Character("\\").asciiValue {
                    isEscaped = true
                } else if byte == Character("\"").asciiValue {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if byte == Character("\"").asciiValue {
                isInsideString = true
                output.append(byte)
                index += 1
                continue
            }

            if let replacement = replacements.first(where: { token, _ in
                index + token.count <= bytes.count
                    && Array(bytes[index ..< index + token.count]) == token
            }) {
                output.append(contentsOf: replacement.1)
                index += replacement.0.count
            } else {
                output.append(byte)
                index += 1
            }
        }

        return Data(output)
    }
}
