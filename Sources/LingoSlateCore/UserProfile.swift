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
        storageKey: String = "lingoslate.user-profile.v1",
        legacyStorageKeys: [String] = ["leccue.user-profile.v1"],
        legacyBundleIdentifiers: [String] = ["com.timmor51z.leccue"],
        defaultRegionCode: String = Locale.current.region?.identifier ?? "US"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        func decodedProfile(for key: String) -> UserProfile? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(UserProfile.self, from: data)
        }

        let currentProfile = decodedProfile(for: storageKey)
        let sameDomainLegacyProfile = legacyStorageKeys.lazy.compactMap {
            decodedProfile(for: $0)
        }.first
        let legacyBundleProfile: UserProfile? = legacyBundleIdentifiers.lazy.compactMap {
            bundleIdentifier -> UserProfile? in
            guard let legacyDefaults = UserDefaults(suiteName: bundleIdentifier) else {
                return nil
            }
            return ([storageKey] + legacyStorageKeys).lazy.compactMap { key -> UserProfile? in
                guard let data = legacyDefaults.data(forKey: key) else { return nil }
                return try? JSONDecoder().decode(UserProfile.self, from: data)
            }.first
        }.first
        let legacyProfile = sameDomainLegacyProfile ?? legacyBundleProfile
        if let storedProfile = currentProfile ?? legacyProfile {
            schoolName = storedProfile.schoolName
            regionCode = storedProfile.regionCode
            if currentProfile == nil,
               let data = try? JSONEncoder().encode(storedProfile) {
                defaults.set(data, forKey: storageKey)
            }
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

        var terms = [
            term("paper code", "课程代码", aliases: ["paper codes"]),
            term("paper outline", "课程大纲", aliases: ["paper outlines"]),
            term("paper convener", "课程负责人", aliases: ["paper conveners"]),
            term("tutorial stream", "辅导课班次", aliases: ["tutorial streams"]),
            term("lab stream", "实验课班次", aliases: ["lab streams"]),
            term("attend the lab", "参加实验课", aliases: ["attending the lab"]),
            term("prioritize the tutorials", "优先参加辅导课"),
        ]
        if profile.schoolName.localizedCaseInsensitiveContains("Waikato") {
            terms.append(contentsOf: [
                term("MyWaikato", "MyWaikato", aliases: ["My Way Kato", "My Waikato"]),
                term("Waikato", "Waikato", aliases: ["Way Kato", "Wai Kato"]),
                term("Moodle", "Moodle"),
                term("Panopto", "Panopto", aliases: ["Panoptos"]),
                term("FG Link", "FG Link"),
                term("Gate 1", "Gate 1", aliases: ["Gate One", "K1"]),
                term("Larkin Road", "Larkin Road", aliases: ["Larkin Rd"]),
            ])
        }
        return terms
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
