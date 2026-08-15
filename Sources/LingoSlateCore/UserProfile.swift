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

public enum CourseNameNormalizer {
    private static let corrections = [
        "aplication": "Application",
        "architechture": "Architecture",
        "computng": "Computing",
        "enginering": "Engineering",
        "enginerring": "Engineering",
        "enginnering": "Engineering",
        "engineerng": "Engineering",
        "managment": "Management",
        "securty": "Security",
    ]

    public static func normalize(_ courseName: String) -> String {
        let trimmed = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = trimmed
        let expression = try? NSRegularExpression(pattern: #"[\p{L}]+"#)
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = expression?.matches(in: result, range: range) ?? []
        let mutable = NSMutableString(string: result)
        for match in matches.reversed() {
            let word = mutable.substring(with: match.range).lowercased()
            guard let replacement = corrections[word] else { continue }
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        result = mutable as String
        return result
    }
}

public enum CourseTermSeedBuilder {
    private static let baselineAcademicTerms = [
        "course code",
        "peer evaluation",
        "in-text citation",
        "Google Scholar",
        "Overleaf",
        "IEEE",
        "ACM",
        "Scopus",
    ]

    private static let cloudAndSecurityTerms = [
        "AWS",
        "Azure",
        "Google Cloud",
        "IaaS",
        "PaaS",
        "SaaS",
        "NIST",
        "EC2",
        "S3",
        "CloudTrail",
        "Lambda",
        "SageMaker",
        "IAM",
        "MFA",
        "OAuth",
        "OpenID Connect",
        "TLS",
        "Kubernetes",
        "Docker",
        "serverless",
        "API gateway",
        "OWASP",
        "CVE",
        "SQL injection",
        "cross-site scripting",
        "CSRF",
        "least privilege",
        "zero trust",
    ]

    private static let softwareTerms = [
        "GitHub",
        "Git",
        "REST API",
        "JSON",
        "CI/CD",
        "unit testing",
        "integration testing",
        "software architecture",
        "deployment pipeline",
    ]

    private static let mobileTerms = [
        "Android Studio",
        "Jetpack Compose",
        "Kotlin",
        "XML",
        "Android Manifest",
        "Activity",
        "Composable",
        "emulator",
        "runtime permission",
    ]

    public static func suggestions(
        courseName: String,
        schoolName: String
    ) -> [String] {
        var candidates: [String] = []
        let schoolName = schoolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !schoolName.isEmpty {
            candidates.append(schoolName)
        }

        let courseName = CourseNameNormalizer.normalize(courseName)
        if !courseName.isEmpty {
            candidates.append(courseName)
        }

        var separatedCourseName = courseName
        for separator in [" and ", " & ", "/", ",", ":"] {
            separatedCourseName = separatedCourseName.replacingOccurrences(
                of: separator,
                with: "|",
                options: .caseInsensitive
            )
        }
        let titleParts = separatedCourseName.split(separator: "|").map(String.init)
        candidates.append(contentsOf: titleParts)

        for titlePart in titleParts {
            let titleWords = titlePart.split(whereSeparator: \.isWhitespace).map { rawWord in
                String(rawWord).trimmingCharacters(in: .punctuationCharacters)
            }.filter { $0.count >= 4 }
            if titleWords.count >= 3 {
                for index in 0..<(titleWords.count - 1) {
                    candidates.append("\(titleWords[index]) \(titleWords[index + 1])")
                }
            }
        }

        candidates.append(contentsOf: baselineAcademicTerms)
        let lowercaseCourseName = courseName.lowercased()
        if ["cloud", "security", "secure", "cyber"].contains(where: lowercaseCourseName.contains) {
            candidates.append(contentsOf: cloudAndSecurityTerms)
        }
        if ["application", "software", "engineering", "computing", "programming", "development"]
            .contains(where: lowercaseCourseName.contains) {
            candidates.append(contentsOf: softwareTerms)
        }
        if ["mobile", "wearable", "android"].contains(where: lowercaseCourseName.contains) {
            candidates.append(contentsOf: mobileTerms)
        }

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 3 else { return nil }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return term
        }.prefix(48).map { $0 }
    }
}

public enum RegionalAcademicGlossary {
    public static func approvedTerms(for profile: UserProfile) -> [GlossaryTerm] {
        var terms = [
            term("Google Scholar", "Google Scholar"),
            term("Overleaf", "Overleaf", aliases: ["Over leaf"]),
            term("IEEE", "IEEE", aliases: ["I triple E"]),
            term("ACM", "ACM", aliases: ["A C M"]),
            term("Scopus", "Scopus", aliases: ["Scope us"]),
            term("LLM", "LLM", aliases: ["LLMs", "LLEM", "LLEMs"]),
            term("ChatGPT", "ChatGPT"),
            term("DeepSeek", "DeepSeek", aliases: ["Deep Seek"]),
            term("Claude Code", "Claude Code"),
            term("Android Studio", "Android Studio"),
            term("Jetpack Compose", "Jetpack Compose", aliases: ["Jet Pack Compose"]),
            term("Kotlin", "Kotlin", aliases: ["Scotlin"]),
            term("XML", "XML"),
            term("peer evaluation", "同伴互评", aliases: ["peer assessment"]),
            term("in-text citation", "文内引用", aliases: ["in text citation"]),
            term("deduction of marks", "扣分", aliases: ["mark deduction"]),
        ]
        guard profile.regionCode == "NZ" else { return terms }

        terms.append(contentsOf: [
            term("paper code", "课程代码", aliases: ["paper codes"]),
            term("paper outline", "课程大纲", aliases: ["paper outlines"]),
            term("paper convener", "课程负责人", aliases: ["paper conveners"]),
            term("tutorial stream", "辅导课班次", aliases: ["tutorial streams"]),
            term("lab stream", "实验课班次", aliases: ["lab streams"]),
            term("attend the lab", "参加实验课", aliases: ["attending the lab"]),
            term("prioritize the tutorials", "优先参加辅导课"),
        ])
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

public enum CourseTranslationGlossary {
    public static func approvedTerms(for course: Course) -> [GlossaryTerm] {
        let context = ([course.name] + (course.recognitionTerms ?? []))
            .joined(separator: " ")
            .lowercased()
        guard ["cloud", "aws", "azure", "iaas", "paas", "saas", "nist"]
            .contains(where: context.contains) else { return [] }

        return [
            term("NIST", "NIST"),
            term("CloudTrail", "CloudTrail", aliases: ["AWS CloudTrail"]),
            term("cloud consumer", "云服务消费者", aliases: ["cloud consumers"]),
            term(
                "cloud service provider",
                "云服务提供商",
                aliases: ["cloud service providers", "cloud provider", "cloud providers"]
            ),
            term("cloud auditor", "云服务审计方", aliases: ["cloud auditors"]),
            term("cloud broker", "云服务经纪商", aliases: ["cloud brokers"]),
            term("security group", "安全组", aliases: ["security groups"]),
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
            origin: .sessionSuggestion,
            isApproved: true
        )
    }
}
