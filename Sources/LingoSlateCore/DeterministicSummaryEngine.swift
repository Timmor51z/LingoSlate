import Foundation

public struct DeterministicSummaryEngine: SummaryEngine {
    public init() {}

    public func summarize(_ document: SessionDocument) async throws -> SessionSummary {
        Self.makeSummary(for: document)
    }

    public static func makeSummary(for document: SessionDocument) -> SessionSummary {
        let segments = document.segments
            .filter {
                $0.translationExclusionReason == nil
                    && !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.startTime < $1.startTime }

        guard !segments.isEmpty else {
            return SessionSummary(overview: [], keyConcepts: [], actionItems: [])
        }

        return SessionSummary(
            overview: overview(from: segments),
            keyConcepts: keyConcepts(from: segments, course: document.configuration.course),
            actionItems: actionItems(from: segments, markers: document.markers)
        )
    }

    private static func overview(from segments: [TranscriptSegment]) -> [String] {
        let maximumCount = 5
        let selectedIndices: [Int]
        if segments.count <= maximumCount {
            selectedIndices = Array(segments.indices)
        } else {
            selectedIndices = (0..<maximumCount).map { position in
                Int(
                    (Double(position) * Double(segments.count - 1) / Double(maximumCount - 1))
                        .rounded()
                )
            }
        }

        return unique(
            selectedIndices.map { displayText(for: segments[$0]) },
            limit: maximumCount
        )
    }

    private static func keyConcepts(
        from segments: [TranscriptSegment],
        course: Course
    ) -> [String] {
        var concepts = course.recognitionTerms ?? []
        var tokenCounts: [String: Int] = [:]
        var tokenForms: [String: String] = [:]
        var tokenOrder: [String: Int] = [:]
        var order = 0

        for segment in segments {
            for token in tokens(in: segment.sourceText) {
                let key = token.lowercased()
                guard !stopWords.contains(key), isConceptCandidate(token) else { continue }
                tokenCounts[key, default: 0] += 1
                tokenForms[key, default: token] = token
                tokenOrder[key, default: order] = order
                order += 1
            }
        }

        let repeatedTokens = tokenCounts.keys
            .filter { tokenCounts[$0, default: 0] >= 2 }
            .sorted { lhs, rhs in
                let leftCount = tokenCounts[lhs, default: 0]
                let rightCount = tokenCounts[rhs, default: 0]
                if leftCount != rightCount { return leftCount > rightCount }
                return tokenOrder[lhs, default: .max] < tokenOrder[rhs, default: .max]
            }
            .compactMap { tokenForms[$0] }

        concepts.append(contentsOf: repeatedTokens)
        if concepts.isEmpty, !course.name.isEmpty {
            concepts.append(course.name)
        }
        return unique(concepts, limit: 8)
    }

    private static func actionItems(
        from segments: [TranscriptSegment],
        markers: [SessionMarker]
    ) -> [String] {
        var items: [String] = []

        for marker in markers where marker.kind == .actionItem {
            guard let nearest = segments.min(by: {
                abs($0.startTime - marker.timestamp) < abs($1.startTime - marker.timestamp)
            }) else { continue }
            items.append(timestamped(displayText(for: nearest), at: nearest.startTime))
        }

        for segment in segments {
            let source = segment.sourceText.lowercased()
            guard containsActionCue(in: source) else { continue }
            items.append(timestamped(displayText(for: segment), at: segment.startTime))
        }

        return unique(items, limit: 8)
    }

    private static func displayText(for segment: TranscriptSegment) -> String {
        let translated = segment.translatedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let translated, !translated.isEmpty {
            return translated
        }
        return segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestamped(_ text: String, at timestamp: TimeInterval) -> String {
        let seconds = max(0, Int(timestamp))
        return String(format: "[%02d:%02d] %@", seconds / 60, seconds % 60, text)
    }

    private static func tokens(in text: String) -> [String] {
        text.split { character in
            !character.isLetter && !character.isNumber && character != "-"
        }.map(String.init)
    }

    private static func containsActionCue(in text: String) -> Bool {
        let words = Set(tokens(in: text))
        return actionCues.contains { cue in
            cue.contains(" ") ? text.contains(cue) : words.contains(cue)
        }
    }

    private static func isConceptCandidate(_ token: String) -> Bool {
        token.count >= 4 || (token.count >= 2 && token == token.uppercased())
    }

    private static func unique(_ values: [String], limit: Int) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count == limit { break }
        }
        return result
    }

    private static let actionCues = [
        "assignment",
        "deadline",
        "due date",
        "due next",
        "submit",
        "submission",
        "remember to",
        "you need to",
        "you should",
        "exam date",
        "quiz date",
        "homework",
        "action item",
    ]

    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "because", "before", "being", "between",
        "could", "course", "during", "every", "first", "from", "have", "into", "just",
        "lecture", "more", "other", "should", "some", "than", "that", "their", "there",
        "these", "they", "this", "those", "through", "today", "using", "very", "what",
        "when", "where", "which", "while", "with", "would", "your",
    ]
}
