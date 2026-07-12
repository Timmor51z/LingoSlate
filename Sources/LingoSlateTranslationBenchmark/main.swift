import LingoSlateCore
import LingoSlateTranslation
import Darwin
import Foundation

private struct LecSyncReference: Decodable {
    var session: ReferenceSession
    var segments: [ReferenceSegment]
}

private struct ReferenceSession: Decodable {
    var id: String
    var title: String?
}

private struct ReferenceSegment: Decodable {
    var index: Int
    var text: String
    var translatedText: String?
}

private struct SegmentReport: Codable {
    var index: Int
    var sourceText: String
    var competitorTranslation: String
    var candidateTranslation: String
    var latencySeconds: Double
    var characterFScore: Double
    var numericTokenRecall: Double?
    var protectedTermRecall: Double?
    var glossaryTargetRecall: Double?
}

private struct TranslationReport: Codable {
    var schemaVersion = 1
    var generatedAt: Date
    var referenceKind: String
    var referenceSessionID: String
    var model: String
    var sampleCount: Int
    var modelLoadSeconds: Double
    var meanLatencySeconds: Double
    var medianLatencySeconds: Double
    var meanCharacterFScore: Double
    var numericTokenRecall: Double?
    var protectedTermRecall: Double?
    var glossaryTargetRecall: Double?
    var terms: [String]
    var glossary: [String: String]
    var minimumWords: Int
    var maximumWords: Int
    var segments: [SegmentReport]
    var caveats: [String]
}

private struct Options {
    var sampleCount = 24
    var terms: [String] = []
    var glossary: [String: String] = [:]
    var minimumWords = 6
    var maximumWords = 36
    var referenceURL: URL
    var reportURL: URL

    static func parse(_ arguments: [String]) throws -> Options {
        var sampleCount = 24
        var terms: [String] = []
        var glossary: [String: String] = [:]
        var minimumWords = 6
        var maximumWords = 36
        var paths: [String] = []
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--sample-count":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]), value > 0 else {
                    throw BenchmarkError.invalidArguments
                }
                sampleCount = value
            case "--term":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkError.invalidArguments
                }
                terms.append(arguments[index])
            case "--glossary":
                index += 1
                guard index < arguments.count,
                      let separator = arguments[index].firstIndex(of: "=") else {
                    throw BenchmarkError.invalidArguments
                }
                let source = String(arguments[index][..<separator])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let target = String(arguments[index][arguments[index].index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty, !target.isEmpty else {
                    throw BenchmarkError.invalidArguments
                }
                glossary[source] = target
            case "--minimum-words":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]), value >= 0 else {
                    throw BenchmarkError.invalidArguments
                }
                minimumWords = value
            case "--maximum-words":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]), value > 0 else {
                    throw BenchmarkError.invalidArguments
                }
                maximumWords = value
            default:
                paths.append(arguments[index])
            }
            index += 1
        }

        guard paths.count == 2 else {
            throw BenchmarkError.invalidArguments
        }
        guard minimumWords <= maximumWords else {
            throw BenchmarkError.invalidArguments
        }
        return Options(
            sampleCount: sampleCount,
            terms: terms,
            glossary: glossary,
            minimumWords: minimumWords,
            maximumWords: maximumWords,
            referenceURL: URL(fileURLWithPath: paths[0]),
            reportURL: URL(fileURLWithPath: paths[1])
        )
    }
}

private enum BenchmarkError: LocalizedError {
    case invalidArguments
    case modelUnavailable
    case noTranslatedSegments

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: swift run LingoSlateTranslationBenchmark [--sample-count N] "
                + "[--minimum-words N] [--maximum-words N] [--term TERM]... "
                + "[--glossary SOURCE=TARGET]... <reference.json> <report.json>"
        case .modelUnavailable:
            return "TranslateGemma could not be prepared"
        case .noTranslatedSegments:
            return "The reference contains no translated segments"
        }
    }
}

@main
private struct LingoSlateTranslationBenchmark {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(
                Data("LingoSlateTranslationBenchmark: \(error.localizedDescription)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        let reference = try JSONDecoder().decode(
            LecSyncReference.self,
            from: Data(contentsOf: options.referenceURL)
        )
        let translatedSegments = reference.segments.filter {
            let wordCount = $0.text.split(whereSeparator: \.isWhitespace).count
            return !($0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && !(($0.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && wordCount >= options.minimumWords
                && wordCount <= options.maximumWords
        }
        guard !translatedSegments.isEmpty else {
            throw BenchmarkError.noTranslatedSegments
        }

        let samples = evenlySpacedSamples(
            translatedSegments,
            count: min(options.sampleCount, translatedSegments.count)
        )
        let course = Course(
            name: reference.session.title ?? "Translation benchmark",
            recognitionTerms: options.terms
        )
        let engine = TranslateGemmaTranslationEngine()
        let loadStartedAt = Date()
        guard await engine.prepare() else {
            throw BenchmarkError.modelUnavailable
        }
        let modelLoadSeconds = Date().timeIntervalSince(loadStartedAt)

        var reports: [SegmentReport] = []
        var recentSourceText: [String] = []
        var numericReferenceCount = 0
        var numericMatchedCount = 0
        var termReferenceCount = 0
        var termMatchedCount = 0
        var glossaryReferenceCount = 0
        var glossaryMatchedCount = 0
        let glossaryTerms = options.glossary.map { source, target in
            GlossaryTerm(
                source: source,
                target: target,
                origin: .user,
                isApproved: true
            )
        }

        for (offset, segment) in samples.enumerated() {
            let startedAt = Date()
            let translation = try await engine.translate(
                segment.text,
                context: TranslationContext(
                    course: course,
                    recentSourceText: Array(recentSourceText.suffix(4)),
                    approvedTerms: glossaryTerms
                )
            )
            let latency = Date().timeIntervalSince(startedAt)
            let competitor = segment.translatedText ?? ""

            let numberRecall = tokenRecall(
                referenceTokens: numericTokens(in: segment.text),
                candidate: translation
            )
            numericReferenceCount += numberRecall.referenceCount
            numericMatchedCount += numberRecall.matchedCount

            let presentTerms = options.terms.filter {
                contains($0, in: segment.text)
            }
            let termRecall = tokenRecall(
                referenceTokens: presentTerms,
                candidate: translation
            )
            termReferenceCount += termRecall.referenceCount
            termMatchedCount += termRecall.matchedCount

            let presentGlossary = options.glossary.filter { source, _ in
                contains(source, in: segment.text)
            }
            let glossaryMatched = presentGlossary.values.filter {
                contains($0, in: translation)
            }.count
            glossaryReferenceCount += presentGlossary.count
            glossaryMatchedCount += glossaryMatched

            reports.append(
                SegmentReport(
                    index: segment.index,
                    sourceText: segment.text,
                    competitorTranslation: competitor,
                    candidateTranslation: translation,
                    latencySeconds: latency,
                    characterFScore: characterFScore(
                        reference: competitor,
                        candidate: translation
                    ),
                    numericTokenRecall: numberRecall.rate,
                    protectedTermRecall: termRecall.rate,
                    glossaryTargetRecall: rate(
                        matched: glossaryMatched,
                        reference: presentGlossary.count
                    )
                )
            )
            recentSourceText.append(segment.text)
            print("Translated sample \(offset + 1)/\(samples.count), segment \(segment.index)")
        }

        let latencies = reports.map(\.latencySeconds).sorted()
        let report = TranslationReport(
            generatedAt: Date(),
            referenceKind: "LecSync competitor output; not manually corrected ground truth",
            referenceSessionID: reference.session.id,
            model: engine.identifier,
            sampleCount: reports.count,
            modelLoadSeconds: modelLoadSeconds,
            meanLatencySeconds: mean(latencies),
            medianLatencySeconds: median(latencies),
            meanCharacterFScore: mean(reports.map(\.characterFScore)),
            numericTokenRecall: rate(
                matched: numericMatchedCount,
                reference: numericReferenceCount
            ),
            protectedTermRecall: rate(
                matched: termMatchedCount,
                reference: termReferenceCount
            ),
            glossaryTargetRecall: rate(
                matched: glossaryMatchedCount,
                reference: glossaryReferenceCount
            ),
            terms: options.terms,
            glossary: options.glossary,
            minimumWords: options.minimumWords,
            maximumWords: options.maximumWords,
            segments: reports,
            caveats: [
                "LecSync Chinese output is a competitor baseline, not ground truth.",
                "Character F-score is a local 1...6 character n-gram F2 diagnostic; it does not measure semantic equivalence.",
                "Human bilingual review is required before making translation-accuracy claims.",
                "The sampled source is LecSync English so this report isolates translation from LingoSlate ASR errors.",
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

        print(String(format: "Mean character F-score: %.2f", report.meanCharacterFScore * 100))
        print(String(format: "Median translation latency: %.2f s", report.medianLatencySeconds))
        print("Report: \(options.reportURL.path)")
    }

    private static func evenlySpacedSamples(
        _ segments: [ReferenceSegment],
        count: Int
    ) -> [ReferenceSegment] {
        guard count > 1 else { return [segments[segments.count / 2]] }
        return (0..<count).map { offset in
            let position = Double(offset) * Double(segments.count - 1) / Double(count - 1)
            return segments[Int(position.rounded())]
        }
    }

    private static func characterFScore(reference: String, candidate: String) -> Double {
        let referenceCharacters = normalizedCharacters(reference)
        let candidateCharacters = normalizedCharacters(candidate)
        guard !referenceCharacters.isEmpty else {
            return candidateCharacters.isEmpty ? 1 : 0
        }

        var scores: [Double] = []
        for width in 1...6 {
            let referenceCounts = ngramCounts(referenceCharacters, width: width)
            let candidateCounts = ngramCounts(candidateCharacters, width: width)
            guard !referenceCounts.isEmpty, !candidateCounts.isEmpty else { continue }

            let overlap = referenceCounts.reduce(0) { partial, entry in
                partial + min(entry.value, candidateCounts[entry.key, default: 0])
            }
            let precision = Double(overlap) / Double(candidateCounts.values.reduce(0, +))
            let recall = Double(overlap) / Double(referenceCounts.values.reduce(0, +))
            let betaSquared = 4.0
            let denominator = betaSquared * precision + recall
            scores.append(
                denominator > 0
                    ? (1 + betaSquared) * precision * recall / denominator
                    : 0
            )
        }
        return mean(scores)
    }

    private static func normalizedCharacters(_ text: String) -> [Character] {
        Array(text.lowercased().filter { character in
            character.unicodeScalars.contains { scalar in
                CharacterSet.letters.contains(scalar)
                    || CharacterSet.decimalDigits.contains(scalar)
            }
        })
    }

    private static func ngramCounts(
        _ characters: [Character],
        width: Int
    ) -> [String: Int] {
        guard characters.count >= width else { return [:] }
        var counts: [String: Int] = [:]
        for start in 0...(characters.count - width) {
            let gram = String(characters[start..<(start + width)])
            counts[gram, default: 0] += 1
        }
        return counts
    }

    private static func numericTokens(in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\b\d+(?:[.:]\d+)*\b"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func tokenRecall(
        referenceTokens: [String],
        candidate: String
    ) -> (matchedCount: Int, referenceCount: Int, rate: Double?) {
        let matched = referenceTokens.filter { contains($0, in: candidate) }.count
        return (
            matched,
            referenceTokens.count,
            rate(matched: matched, reference: referenceTokens.count)
        )
    }

    private static func contains(_ token: String, in text: String) -> Bool {
        text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let middle = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middle - 1] + sortedValues[middle]) / 2
        }
        return sortedValues[middle]
    }

    private static func rate(matched: Int, reference: Int) -> Double? {
        reference > 0 ? Double(matched) / Double(reference) : nil
    }
}
