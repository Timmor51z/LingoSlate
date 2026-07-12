import Foundation

public struct IncrementalTranscriptCursor: Sendable {
    public private(set) var committedTranscript: String

    public init(committedTranscript: String = "") {
        self.committedTranscript = committedTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    public func uncommittedText(in transcript: String) -> String {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committedTranscript.isEmpty else { return normalized }

        let committedWords = words(in: committedTranscript)
        let incomingWords = words(in: normalized)
        guard incomingWords.count >= committedWords.count else { return "" }

        let hasCommittedPrefix = zip(committedWords, incomingWords).allSatisfy { pair in
            comparableToken(pair.0) == comparableToken(pair.1)
        }
        let boundary: Int
        if hasCommittedPrefix {
            boundary = committedWords.count
        } else {
            boundary = anchoredBoundary(
                committedWords: committedWords,
                incomingWords: incomingWords
            ) ?? committedWords.count
        }

        return incomingWords
            .dropFirst(boundary)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func commit(_ transcript: String) {
        committedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func words(in text: String) -> [Substring] {
        text.split(whereSeparator: \Character.isWhitespace)
    }

    private func comparableToken(_ token: Substring) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private func anchoredBoundary(
        committedWords: [Substring],
        incomingWords: [Substring]
    ) -> Int? {
        let maximumAnchorLength = min(8, committedWords.count)
        guard maximumAnchorLength >= 2 else { return nil }

        for anchorLength in stride(from: maximumAnchorLength, through: 2, by: -1) {
            let anchor = committedWords.suffix(anchorLength).map(comparableToken)
            guard incomingWords.count >= anchorLength else { continue }

            for start in stride(
                from: incomingWords.count - anchorLength,
                through: 0,
                by: -1
            ) {
                let candidate = incomingWords[start..<(start + anchorLength)]
                    .map(comparableToken)
                if candidate == anchor {
                    return start + anchorLength
                }
            }
        }

        return nil
    }
}
