import LingoSlateCore
import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable(description: "A concise Chinese summary of a university lecture or meeting")
private struct GeneratedSessionSummary {
    @Guide(description: "Three to five concise Chinese overview points", .maximumCount(5))
    var overview: [String]

    @Guide(description: "Important concepts, technical terms, and definitions", .maximumCount(8))
    var keyConcepts: [String]

    @Guide(description: "Assignments, deadlines, decisions, and follow-up actions", .maximumCount(8))
    var actionItems: [String]
}
#endif

struct LocalSummaryEngine: SummaryEngine {
    private let fallback = DeterministicSummaryEngine()

    func summarize(_ document: SessionDocument) async throws -> SessionSummary {
        let fallbackSummary = try await fallback.summarize(document)
        guard !fallbackSummary.isEmpty else { return fallbackSummary }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let generated = try await generateSummary(for: document)
                return merge(generated, fallback: fallbackSummary)
            } catch {
                // The extractive fallback keeps post-class notes available offline.
            }
        }
        #endif

        return fallbackSummary
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateSummary(for document: SessionDocument) async throws -> SessionSummary {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: """
            Summarize an English-taught university lecture or meeting for a Chinese-speaking student.
            Use Simplified Chinese, preserve important English technical terms in parentheses, and be concise.
            Base every statement only on the supplied transcript and markers. Never invent deadlines, tasks,
            definitions, names, or conclusions. Keep timestamps on action items when they are supplied.
            """
        )
        let response = try await session.respond(
            to: """
            Course: \(document.configuration.course.name)

            Transcript and markers:
            \(SummaryPromptBuilder.prompt(for: document))
            """,
            generating: GeneratedSessionSummary.self
        )
        return SessionSummary(
            overview: Self.clean(response.content.overview, limit: 5),
            keyConcepts: Self.clean(response.content.keyConcepts, limit: 8),
            actionItems: Self.clean(response.content.actionItems, limit: 8)
        )
    }
    #endif

    private func merge(
        _ generated: SessionSummary,
        fallback: SessionSummary
    ) -> SessionSummary {
        SessionSummary(
            overview: generated.overview.isEmpty ? fallback.overview : generated.overview,
            keyConcepts: Self.clean(generated.keyConcepts + fallback.keyConcepts, limit: 8),
            actionItems: Self.clean(generated.actionItems + fallback.actionItems, limit: 8)
        )
    }

    private static func clean(_ values: [String], limit: Int) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let trimSet = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-•"))

        for value in values {
            let value = value.trimmingCharacters(in: trimSet)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count == limit { break }
        }
        return result
    }
}

enum SummaryPromptBuilder {
    static func prompt(
        for document: SessionDocument,
        maximumCharacters: Int = 14_000,
        maximumSegments: Int = 80
    ) -> String {
        let segments = document.segments.sorted { $0.startTime < $1.startTime }
        let selectedSegments = evenlySampled(segments, limit: maximumSegments)
        var lines: [String] = []
        var characterCount = 0

        for segment in selectedSegments {
            let line = transcriptLine(for: segment)
            guard characterCount + line.count <= maximumCharacters else { break }
            lines.append(line)
            characterCount += line.count
        }

        let markerLines = document.markers.sorted { $0.timestamp < $1.timestamp }.map { marker in
            "MARKER \(marker.kind.rawValue) \(timestamp(marker.timestamp))"
        }
        lines.append(contentsOf: markerLines)
        return lines.joined(separator: "\n")
    }

    private static func transcriptLine(for segment: TranscriptSegment) -> String {
        let translated = segment.translatedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let translated, !translated.isEmpty {
            return "\(timestamp(segment.startTime)) EN: \(segment.sourceText) ZH: \(translated)"
        }
        return "\(timestamp(segment.startTime)) EN: \(segment.sourceText)"
    }

    private static func evenlySampled<T>(_ values: [T], limit: Int) -> [T] {
        guard limit > 0, values.count > limit else { return values }
        return (0..<limit).map { position in
            let index = Int(
                (Double(position) * Double(values.count - 1) / Double(limit - 1)).rounded()
            )
            return values[index]
        }
    }

    private static func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "[%02d:%02d]", seconds / 60, seconds % 60)
    }
}
