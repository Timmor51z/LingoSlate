import Foundation

public struct IncrementalTranscriptCursor: Sendable {
    public private(set) var committedTranscript: String
    private var committedWords: [String]

    public init(committedTranscript: String = "") {
        let committedTranscript = committedTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.committedTranscript = committedTranscript
        committedWords = Self.words(in: committedTranscript).map(Self.comparableToken)
    }

    public func uncommittedText(in transcript: String) -> String {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committedTranscript.isEmpty else { return normalized }

        if normalized.hasPrefix(committedTranscript) {
            let boundary = normalized.index(
                normalized.startIndex,
                offsetBy: committedTranscript.count
            )
            return Self.trimmingLeadingSeparators(String(normalized[boundary...]))
        }

        let incomingWords = Self.words(in: normalized)
        guard incomingWords.count >= committedWords.count else { return "" }
        let incomingComparableWords = incomingWords.map(Self.comparableToken)

        let hasCommittedPrefix = zip(committedWords, incomingComparableWords).allSatisfy { pair in
            pair.0 == pair.1
        }
        let boundary: Int
        if hasCommittedPrefix {
            boundary = committedWords.count
        } else {
            boundary = anchoredBoundary(
                committedWords: committedWords,
                incomingWords: incomingComparableWords
            ) ?? committedWords.count
        }

        return incomingWords
            .dropFirst(boundary)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func commit(_ transcript: String) {
        committedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        committedWords = Self.words(in: committedTranscript).map(Self.comparableToken)
    }

    private static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: \Character.isWhitespace)
    }

    private static func comparableToken(_ token: Substring) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private func anchoredBoundary(
        committedWords: [String],
        incomingWords: [String]
    ) -> Int? {
        let maximumAnchorLength = min(8, committedWords.count)
        guard maximumAnchorLength >= 2 else { return nil }

        for anchorLength in stride(from: maximumAnchorLength, through: 2, by: -1) {
            let anchor = committedWords.suffix(anchorLength)
            guard incomingWords.count >= anchorLength else { continue }

            for start in stride(
                from: incomingWords.count - anchorLength,
                through: 0,
                by: -1
            ) {
                let candidate = incomingWords[start..<(start + anchorLength)]
                if candidate == anchor {
                    return start + anchorLength
                }
            }
        }

        return nil
    }

    private static func trimmingLeadingSeparators(_ text: String) -> String {
        guard let start = text.firstIndex(where: { character in
            !character.isWhitespace && !character.isPunctuation
        }) else { return "" }
        return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
