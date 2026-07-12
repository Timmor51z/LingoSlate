import Foundation

public struct TranscriptTermNormalizer: Sendable {
    private struct PreferredTerm: Sendable {
        var canonical: String
        var normalized: String
        var expectedWordCount: Int
        var minimumSimilarity: Double

        var allowsFuzzyMatching: Bool {
            normalized.count >= 6
        }
    }

    private struct WordToken {
        var text: String
        var range: NSRange
    }

    private static let wordExpression = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+"#
    )

    private let terms: [PreferredTerm]

    public init(course: Course) {
        self.init(
            preferredTerms: course.recognitionTerms ?? [],
            conservativeTerms: Self.courseNameTerms(course.name)
        )
    }

    public init(course: Course, approvedTerms: [GlossaryTerm]) {
        let preferred = (course.recognitionTerms ?? []).map {
            (canonical: $0, match: $0, minimumSimilarity: 0.84)
        }
        let glossary = approvedTerms.filter(\.isApproved).flatMap { term in
            [(canonical: term.source, match: term.source, minimumSimilarity: 0.84)]
                + term.aliases.map {
                    (canonical: term.source, match: $0, minimumSimilarity: 0.92)
                }
        }
        let conservative = Self.courseNameTerms(course.name).map {
            (canonical: $0, match: $0, minimumSimilarity: 0.92)
        }
        self.init(weightedTerms: preferred + glossary + conservative)
    }

    public init(
        preferredTerms: [String],
        conservativeTerms: [String] = []
    ) {
        let weightedTerms = preferredTerms.map {
            (canonical: $0, match: $0, minimumSimilarity: 0.84)
        } + conservativeTerms.map {
            (canonical: $0, match: $0, minimumSimilarity: 0.92)
        }
        self.init(weightedTerms: weightedTerms)
    }

    private init(
        weightedTerms: [(canonical: String, match: String, minimumSimilarity: Double)]
    ) {
        var seen: Set<String> = []
        var prepared: [PreferredTerm] = []

        for weightedTerm in weightedTerms {
            let canonical = weightedTerm.canonical
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let match = weightedTerm.match
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = Self.normalizedTerm(match)
            let deduplicationKey = "\(normalized)\u{0}\(canonical.lowercased())"
            guard normalized.count >= 2,
                  !canonical.isEmpty,
                  seen.insert(deduplicationKey).inserted else { continue }
            prepared.append(
                PreferredTerm(
                    canonical: canonical,
                    normalized: normalized,
                    expectedWordCount: max(1, Self.words(in: match).count),
                    minimumSimilarity: weightedTerm.minimumSimilarity
                )
            )
        }

        terms = prepared.sorted { lhs, rhs in
            lhs.normalized.count > rhs.normalized.count
        }
    }

    public func normalize(_ text: String) -> String {
        var result = text
        for term in terms {
            result = replacingMatches(for: term, in: result)
        }
        return result
    }

    private func replacingMatches(
        for term: PreferredTerm,
        in text: String
    ) -> String {
        let tokens = Self.words(in: text)
        guard !tokens.isEmpty else { return text }

        var replacements: [(range: NSRange, text: String)] = []
        var tokenIndex = 0
        while tokenIndex < tokens.count {
            var bestMatch: (endIndex: Int, range: NSRange, similarity: Double)?
            let maximumWordCount = min(
                tokens.count - tokenIndex,
                term.expectedWordCount + 2
            )

            for wordCount in 1...maximumWordCount {
                let endIndex = tokenIndex + wordCount
                let candidateTokens = tokens[tokenIndex..<endIndex]
                let candidate = candidateTokens.map(\.text).joined()
                let normalizedCandidate = Self.normalizedTerm(candidate)
                guard let firstCandidate = normalizedCandidate.first,
                      let firstTerm = term.normalized.first,
                      firstCandidate == firstTerm else { continue }

                let similarity: Double
                if normalizedCandidate == term.normalized {
                    similarity = 1
                } else {
                    guard term.allowsFuzzyMatching else { continue }
                    similarity = Self.similarity(
                        normalizedCandidate,
                        term.normalized
                    )
                    guard similarity >= term.minimumSimilarity else { continue }
                }

                guard let startRange = candidateTokens.first?.range,
                      let endRange = candidateTokens.last?.range else { continue }
                let range = NSRange(
                    location: startRange.location,
                    length: NSMaxRange(endRange) - startRange.location
                )
                if similarity > (bestMatch?.similarity ?? -.infinity) {
                    bestMatch = (endIndex, range, similarity)
                }
            }

            if let bestMatch {
                replacements.append((bestMatch.range, term.canonical))
                tokenIndex = bestMatch.endIndex
            } else {
                tokenIndex += 1
            }
        }

        guard !replacements.isEmpty else { return text }
        let mutableText = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            mutableText.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return mutableText as String
    }

    private static func courseNameTerms(_ courseName: String) -> [String] {
        var separated = courseName
        for separator in [" and ", " & ", "/", ",", ":"] {
            separated = separated.replacingOccurrences(
                of: separator,
                with: "|",
                options: .caseInsensitive
            )
        }

        let parts = separated.split(separator: "|").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { normalizedTerm($0).count >= 6 }
        return [courseName] + parts
    }

    private static func words(in text: String) -> [WordToken] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordExpression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return WordToken(text: String(text[swiftRange]), range: match.range)
        }
    }

    private static func normalizedTerm(_ text: String) -> String {
        text.lowercased().unicodeScalars.compactMap { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : nil
        }.joined()
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        let denominator = max(lhsCharacters.count, rhsCharacters.count)
        guard denominator > 0 else { return 1 }

        var previous = Array(0...rhsCharacters.count)
        var current = [Int](repeating: 0, count: rhsCharacters.count + 1)
        for lhsIndex in lhsCharacters.indices {
            current[0] = lhsIndex + 1
            for rhsIndex in rhsCharacters.indices {
                if lhsCharacters[lhsIndex] == rhsCharacters[rhsIndex] {
                    current[rhsIndex + 1] = previous[rhsIndex]
                } else {
                    current[rhsIndex + 1] = min(
                        previous[rhsIndex],
                        previous[rhsIndex + 1],
                        current[rhsIndex]
                    ) + 1
                }
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[rhsCharacters.count]) / Double(denominator)
    }
}
