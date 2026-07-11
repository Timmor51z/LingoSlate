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
