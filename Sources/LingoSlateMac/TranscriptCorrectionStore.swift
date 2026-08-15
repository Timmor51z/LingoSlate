import LingoSlateCore
import Foundation

@MainActor
final class TranscriptCorrectionStore {
    private struct Correction: Codable {
        var contextKey: String
        var heard: String
        var corrected: String
    }

    private let defaults: UserDefaults
    private let storageKey = "lingoslate.transcript-corrections.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func approvedTerms(for course: Course) -> [GlossaryTerm] {
        let key = contextKey(for: course)
        return corrections.filter { $0.contextKey == key }.map { correction in
            GlossaryTerm(
                source: correction.corrected,
                target: correction.corrected,
                aliases: [correction.heard],
                origin: .user,
                confidence: 1,
                isApproved: true
            )
        }
    }

    func record(heard: String, corrected: String, course: Course) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !corrected.isEmpty,
              heard.caseInsensitiveCompare(corrected) != .orderedSame else { return }
        var values = corrections
        let key = contextKey(for: course)
        values.removeAll {
            $0.contextKey == key && $0.heard.caseInsensitiveCompare(heard) == .orderedSame
        }
        values.append(Correction(contextKey: key, heard: heard, corrected: corrected))
        if values.count > 64 {
            values.removeFirst(values.count - 64)
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private var corrections: [Correction] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Correction].self, from: data)) ?? []
    }

    private func contextKey(for course: Course) -> String {
        [
            course.name,
            course.lecturerNames.first ?? "",
            course.lecturerAccent?.rawValue ?? "",
        ]
        .map {
            $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        .joined(separator: "|")
    }
}
