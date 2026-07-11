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
        guard incomingWords.count >= committedWords.count else { return normalized }

        let hasCommittedPrefix = zip(committedWords, incomingWords).allSatisfy { pair in
            comparableToken(pair.0) == comparableToken(pair.1)
        }
        guard hasCommittedPrefix else { return normalized }

        return incomingWords
            .dropFirst(committedWords.count)
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
}
