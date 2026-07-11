import Foundation

public struct WordErrorBreakdown: Codable, Hashable, Sendable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceWordCount: Int
    public var hypothesisWordCount: Int

    public init(
        substitutions: Int = 0,
        deletions: Int = 0,
        insertions: Int = 0,
        referenceWordCount: Int = 0,
        hypothesisWordCount: Int = 0
    ) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceWordCount = referenceWordCount
        self.hypothesisWordCount = hypothesisWordCount
    }

    public var totalEdits: Int {
        substitutions + deletions + insertions
    }

    public var errorRate: Double {
        guard referenceWordCount > 0 else {
            return hypothesisWordCount == 0 ? 0 : 1
        }
        return Double(totalEdits) / Double(referenceWordCount)
    }

    public func adding(_ other: WordErrorBreakdown) -> WordErrorBreakdown {
        WordErrorBreakdown(
            substitutions: substitutions + other.substitutions,
            deletions: deletions + other.deletions,
            insertions: insertions + other.insertions,
            referenceWordCount: referenceWordCount + other.referenceWordCount,
            hypothesisWordCount: hypothesisWordCount + other.hypothesisWordCount
        )
    }
}

public struct TokenRecallMetrics: Codable, Hashable, Sendable {
    public var referenceCount: Int
    public var matchedCount: Int

    public init(referenceCount: Int, matchedCount: Int) {
        self.referenceCount = referenceCount
        self.matchedCount = matchedCount
    }

    public var recall: Double? {
        guard referenceCount > 0 else { return nil }
        return Double(matchedCount) / Double(referenceCount)
    }
}

public struct WordCoverageMetrics: Codable, Hashable, Sendable {
    public var referenceWordCount: Int
    public var hypothesisWordCount: Int
    public var matchedWordCount: Int

    public init(
        referenceWordCount: Int,
        hypothesisWordCount: Int,
        matchedWordCount: Int
    ) {
        self.referenceWordCount = referenceWordCount
        self.hypothesisWordCount = hypothesisWordCount
        self.matchedWordCount = matchedWordCount
    }

    public var recall: Double? {
        guard referenceWordCount > 0 else { return nil }
        return Double(matchedWordCount) / Double(referenceWordCount)
    }

    public var precision: Double? {
        guard hypothesisWordCount > 0 else { return nil }
        return Double(matchedWordCount) / Double(hypothesisWordCount)
    }

    public var f1: Double? {
        guard let recall, let precision, recall + precision > 0 else { return nil }
        return 2 * recall * precision / (recall + precision)
    }
}

public enum TranscriptComparison {
    public static func normalizedWords(in text: String) -> [String] {
        var normalized = ""
        normalized.reserveCapacity(text.count)

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
            } else {
                normalized.append(" ")
            }
        }

        return normalized.split(whereSeparator: \Character.isWhitespace).map(String.init)
    }

    public static func wordErrors(
        reference: String,
        hypothesis: String
    ) -> WordErrorBreakdown {
        wordErrors(
            referenceWords: normalizedWords(in: reference),
            hypothesisWords: normalizedWords(in: hypothesis)
        )
    }

    public static func numberTokens(in text: String) -> [String] {
        normalizedWords(in: text).filter { token in
            token.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
        }
    }

    public static func acronymTokens(in text: String) -> [String] {
        text.split(whereSeparator: \Character.isWhitespace).compactMap { rawToken in
            let token = String(rawToken).trimmingCharacters(in: .punctuationCharacters)
            let letters = token.unicodeScalars.filter(CharacterSet.letters.contains)
            guard letters.count >= 2 else { return nil }

            let hasLowercase = letters.contains { CharacterSet.lowercaseLetters.contains($0) }
            let uppercaseCount = letters.count(where: CharacterSet.uppercaseLetters.contains)
            guard !hasLowercase, uppercaseCount >= 2 else { return nil }
            return token.lowercased()
        }
    }

    public static func tokenRecall(
        referenceTokens: [String],
        hypothesisTokens: [String]
    ) -> TokenRecallMetrics {
        var remaining = Dictionary(
            grouping: hypothesisTokens.map { $0.lowercased() },
            by: { $0 }
        ).mapValues(\.count)
        var matched = 0

        for token in referenceTokens.map({ $0.lowercased() }) {
            guard let count = remaining[token], count > 0 else { continue }
            remaining[token] = count - 1
            matched += 1
        }

        return TokenRecallMetrics(
            referenceCount: referenceTokens.count,
            matchedCount: matched
        )
    }

    public static func wordCoverage(
        reference: String,
        hypothesis: String
    ) -> WordCoverageMetrics {
        let referenceWords = normalizedWords(in: reference)
        let hypothesisWords = normalizedWords(in: hypothesis)
        let recall = tokenRecall(
            referenceTokens: referenceWords,
            hypothesisTokens: hypothesisWords
        )

        return WordCoverageMetrics(
            referenceWordCount: referenceWords.count,
            hypothesisWordCount: hypothesisWords.count,
            matchedWordCount: recall.matchedCount
        )
    }

    private static func wordErrors(
        referenceWords: [String],
        hypothesisWords: [String]
    ) -> WordErrorBreakdown {
        let rows = referenceWords.count + 1
        let columns = hypothesisWords.count + 1
        var costs = [Int](repeating: 0, count: rows * columns)
        var operations = [UInt8](repeating: 0, count: rows * columns)

        func index(_ row: Int, _ column: Int) -> Int {
            row * columns + column
        }

        for row in 1..<rows {
            costs[index(row, 0)] = row
            operations[index(row, 0)] = 2
        }
        for column in 1..<columns {
            costs[index(0, column)] = column
            operations[index(0, column)] = 3
        }

        if rows > 1, columns > 1 {
            for row in 1..<rows {
                for column in 1..<columns {
                    if referenceWords[row - 1] == hypothesisWords[column - 1] {
                        costs[index(row, column)] = costs[index(row - 1, column - 1)]
                        operations[index(row, column)] = 0
                        continue
                    }

                    let substitution = costs[index(row - 1, column - 1)] + 1
                    let deletion = costs[index(row - 1, column)] + 1
                    let insertion = costs[index(row, column - 1)] + 1

                    if substitution <= deletion, substitution <= insertion {
                        costs[index(row, column)] = substitution
                        operations[index(row, column)] = 1
                    } else if deletion <= insertion {
                        costs[index(row, column)] = deletion
                        operations[index(row, column)] = 2
                    } else {
                        costs[index(row, column)] = insertion
                        operations[index(row, column)] = 3
                    }
                }
            }
        }

        var row = referenceWords.count
        var column = hypothesisWords.count
        var substitutions = 0
        var deletions = 0
        var insertions = 0

        while row > 0 || column > 0 {
            switch operations[index(row, column)] {
            case 0:
                row -= 1
                column -= 1
            case 1:
                substitutions += 1
                row -= 1
                column -= 1
            case 2:
                deletions += 1
                row -= 1
            case 3:
                insertions += 1
                column -= 1
            default:
                preconditionFailure("Unknown transcript comparison operation")
            }
        }

        return WordErrorBreakdown(
            substitutions: substitutions,
            deletions: deletions,
            insertions: insertions,
            referenceWordCount: referenceWords.count,
            hypothesisWordCount: hypothesisWords.count
        )
    }
}
