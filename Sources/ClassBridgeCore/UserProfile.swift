import Combine
import Foundation

public struct UserProfile: Codable, Hashable, Sendable {
    public var schoolName: String
    public var regionCode: String

    public init(schoolName: String = "", regionCode: String = "") {
        self.schoolName = schoolName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.regionCode = regionCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    public var hasSchool: Bool {
        !schoolName.isEmpty
    }
}

@MainActor
public final class UserProfileStore: ObservableObject {
    @Published public var schoolName: String {
        didSet { persist() }
    }

    @Published public var regionCode: String {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "leccue.user-profile.v1",
        defaultRegionCode: String = Locale.current.region?.identifier ?? "US"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        if let data = defaults.data(forKey: storageKey),
           let storedProfile = try? JSONDecoder().decode(UserProfile.self, from: data) {
            schoolName = storedProfile.schoolName
            regionCode = storedProfile.regionCode
        } else {
            schoolName = ""
            regionCode = defaultRegionCode.uppercased()
        }
    }

    public var profile: UserProfile {
        UserProfile(schoolName: schoolName, regionCode: regionCode)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

public enum CourseTermSeedBuilder {
    public static func suggestions(
        courseName: String,
        schoolName: String
    ) -> [String] {
        var candidates: [String] = []
        let schoolName = schoolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !schoolName.isEmpty {
            candidates.append(schoolName)
        }

        var separatedCourseName = courseName
        for separator in [" and ", " & ", "/", ",", ":"] {
            separatedCourseName = separatedCourseName.replacingOccurrences(
                of: separator,
                with: "|",
                options: .caseInsensitive
            )
        }
        candidates.append(contentsOf: separatedCourseName.split(separator: "|").map(String.init))

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 3 else { return nil }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return term
        }
    }
}

public enum RegionalAcademicGlossary {
    public static func approvedTerms(for profile: UserProfile) -> [GlossaryTerm] {
        guard profile.regionCode == "NZ" else { return [] }

        return [
            term("paper code", "课程代码", aliases: ["paper codes"]),
            term("paper outline", "课程大纲", aliases: ["paper outlines"]),
            term("paper convener", "课程负责人", aliases: ["paper conveners"]),
            term("tutorial stream", "辅导课班次", aliases: ["tutorial streams"]),
            term("lab stream", "实验课班次", aliases: ["lab streams"]),
            term("attend the lab", "参加实验课", aliases: ["attending the lab"]),
            term("prioritize the tutorials", "优先参加辅导课"),
        ]
    }

    private static func term(
        _ source: String,
        _ target: String,
        aliases: [String] = []
    ) -> GlossaryTerm {
        GlossaryTerm(
            source: source,
            target: target,
            aliases: aliases,
            origin: .officialCourseSource,
            confidence: 0.9,
            isApproved: true
        )
    }
}
