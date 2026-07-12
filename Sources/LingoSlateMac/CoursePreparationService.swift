import LingoSlateCore
import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable(description: "English vocabulary likely to appear in a university course")
private struct GeneratedCourseVocabulary {
    @Guide(
        description: "Technical terms, product names, acronyms, and proper nouns",
        .maximumCount(14)
    )
    var terms: [String]
}
#endif

struct CoursePreparationResult: Sendable {
    var terms: [String]
    var usedFoundationModel: Bool
}

struct CoursePreparationService: Sendable {
    func prepare(
        courseName: String,
        profile: UserProfile
    ) async -> CoursePreparationResult {
        let courseName = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let seedTerms = CourseTermSeedBuilder.suggestions(
            courseName: courseName,
            schoolName: profile.schoolName
        )
        guard !courseName.isEmpty else {
            return CoursePreparationResult(
                terms: seedTerms,
                usedFoundationModel: false
            )
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let generatedTerms = try await generateTerms(
                    courseName: courseName,
                    profile: profile
                )
                return CoursePreparationResult(
                    terms: Self.merge(seedTerms, generatedTerms),
                    usedFoundationModel: true
                )
            } catch {
                // Deterministic seed terms keep warmup useful when generation fails.
            }
        }
        #endif

        return CoursePreparationResult(
            terms: seedTerms,
            usedFoundationModel: false
        )
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateTerms(
        courseName: String,
        profile: UserProfile
    ) async throws -> [String] {
        let model = SystemLanguageModel.default
        let session = LanguageModelSession(
            model: model,
            instructions: """
            Prepare a compact vocabulary list for English university speech recognition.
            Return terms only when they are plausibly relevant to the supplied course.
            Do not invent course codes, lecturer names, or institution-specific systems.
            Prefer one to four English words per term and exclude generic classroom words.
            """
        )
        let regionName = Locale(identifier: "en")
            .localizedString(forRegionCode: profile.regionCode) ?? profile.regionCode
        let response = try await session.respond(
            to: """
            Course name: \(courseName)
            Institution: \(profile.schoolName.isEmpty ? "Not provided" : profile.schoolName)
            Country or region: \(regionName)
            """,
            generating: GeneratedCourseVocabulary.self
        )
        return response.content.terms
    }
    #endif

    private static func merge(_ groups: [String]...) -> [String] {
        var seen: Set<String> = []
        return groups.flatMap { $0 }.compactMap { candidate in
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = term.split(whereSeparator: \.isWhitespace).count
            guard term.count >= 2,
                  term.count <= 64,
                  wordCount <= 5,
                  !term.contains(where: \.isNewline) else { return nil }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return term
        }
    }
}
