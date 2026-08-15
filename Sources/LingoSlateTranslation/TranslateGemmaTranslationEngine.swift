import LingoSlateCore
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

public actor TranslateGemmaTranslationEngine: TranslationEngine {
    enum State: Equatable, Sendable {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    public nonisolated let identifier = "translategemma-4b"

    private static let modelID =
        "mlx-community/translategemma-4b-it-4bit_immersive-translate"
    private static let modelRevision = "55fe183d44e6e1fa3e3b1eb2bb8a23f069d515c9"

    private var modelContainer: ModelContainer?
    private(set) var state: State = .idle

    public init() {}

    public func prepare(
        progressHandler: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async -> Bool {
        if modelContainer != nil {
            state = .ready
            return true
        }

        state = .preparing
        do {
            let container: ModelContainer
            if let localModelURL = Self.localModelURL {
                container = try await loadModelContainer(
                    from: localModelURL,
                    using: #huggingFaceTokenizerLoader()
                )
            } else {
                let hub = HubClient(cache: HubCache(cacheDirectory: Self.modelCacheURL))
                container = try await loadModelContainer(
                    from: #hubDownloader(hub),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: ModelConfiguration(
                        id: Self.modelID,
                        revision: Self.modelRevision
                    ),
                    progressHandler: progressHandler
                )
            }
            try Task.checkCancellation()
            modelContainer = container
            state = .ready
            return true
        } catch is CancellationError {
            state = .idle
            return false
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    public func translate(
        _ text: String,
        context: TranslationContext
    ) async throws -> String {
        guard let modelContainer else {
            throw TranslateGemmaError.notReady
        }

        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let preparedInput = TranslateGemmaInputBuilder.make(
            text: text,
            context: context
        )

        let maximumTokens = min(
            320,
            max(64, preparedInput.text.split(whereSeparator: \.isWhitespace).count * 4)
        )
        let session = ChatSession(
            modelContainer,
            generateParameters: GenerateParameters(
                maxTokens: maximumTokens,
                temperature: 0
            )
        )
        let response = try await session.respond(
            to: TranslateGemmaPromptBuilder.make(preparedInput)
        )
        return try TranslateGemmaOutputProcessor.process(
            response,
            sourceText: text,
            preparedInput: preparedInput
        )
    }

    public func release() {
        let wasLoaded = modelContainer != nil
        modelContainer = nil
        if wasLoaded {
            Memory.clearCache()
        }
        state = .idle
    }

    private static var localModelURL: URL? {
        environmentURL(
            primaryKey: "LINGOSLATE_TRANSLATION_MODEL_PATH",
            legacyKey: "LECCUE_TRANSLATION_MODEL_PATH"
        )
    }

    private static var modelCacheURL: URL {
        if let configuredURL = environmentURL(
            primaryKey: "LINGOSLATE_MODEL_CACHE_PATH",
            legacyKey: "LECCUE_MODEL_CACHE_PATH"
        ) {
            return configuredURL
        }

        let fileManager = FileManager.default
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let currentURL = base
            .appendingPathComponent("LingoSlate", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("HuggingFace", isDirectory: true)
        let legacyURL = base
            .appendingPathComponent("ClassBridge", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("HuggingFace", isDirectory: true)

        guard !fileManager.fileExists(atPath: currentURL.path),
              fileManager.fileExists(atPath: legacyURL.path) else {
            return currentURL
        }

        do {
            try fileManager.createDirectory(
                at: currentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyURL, to: currentURL)
            return currentURL
        } catch {
            return legacyURL
        }
    }

    private static func environmentURL(
        primaryKey: String,
        legacyKey: String
    ) -> URL? {
        for key in [primaryKey, legacyKey] {
            if let path = ProcessInfo.processInfo.environment[key], !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }
}

struct TranslateGemmaPreparedInput: Equatable {
    var text: String
    var protectedTerms: [String: String]
    var courseContext: String?
    var recentContext: [String]

    init(
        text: String,
        protectedTerms: [String: String],
        courseContext: String? = nil,
        recentContext: [String] = []
    ) {
        self.text = text
        self.protectedTerms = protectedTerms
        self.courseContext = courseContext
        self.recentContext = recentContext
    }
}

enum TranslateGemmaInputBuilder {
    private struct ReplacementTerm {
        var source: String
        var target: String
        var protectsVerbatim: Bool
    }

    static func make(text: String, context: TranslationContext) -> TranslateGemmaPreparedInput {
        var terms: [ReplacementTerm] = []
        let approvedSources = Set(
            context.approvedTerms.flatMap { [$0.source] + $0.aliases }
                .map { $0.lowercased() }
        )
        if !approvedSources.contains("paper"),
           treatsPaperAsCourse(text: text, context: context) {
            terms.append(
                contentsOf: ["paper", "papers"].map {
                    ReplacementTerm(
                        source: $0,
                        target: "课程",
                        protectsVerbatim: false
                    )
                }
            )
        }
        if !approvedSources.contains("playground"),
           hasSoftwareContext(text: text, context: context) {
            terms.append(
                ReplacementTerm(
                    source: "playground",
                    target: "Playground",
                    protectsVerbatim: true
                )
            )
        }
        for approved in context.approvedTerms {
            let target = approved.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            terms.append(contentsOf: ([approved.source] + approved.aliases).compactMap { source in
                let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { return nil }
                return ReplacementTerm(
                    source: source,
                    target: target,
                    protectsVerbatim: true
                )
            })
        }

        terms.append(contentsOf: (context.course.recognitionTerms ?? []).compactMap { term in
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, shouldProtectRecognitionTerm(term) else { return nil }
            return ReplacementTerm(source: term, target: term, protectsVerbatim: true)
        })
        terms.sort { $0.source.count > $1.source.count }

        var result = text
        var seen: Set<String> = []
        var protectedTerms: [String: String] = [:]
        for term in terms {
            let key = term.source.lowercased()
            guard seen.insert(key).inserted else { continue }
            let replacement: String
            if term.protectsVerbatim {
                replacement = "LINGOSLATEPROPER\(protectedTerms.count)"
                protectedTerms[replacement] = term.target
            } else {
                replacement = term.target
            }
            let replaced = replacingWholeTerm(
                term.source,
                with: replacement,
                in: result
            )
            if replaced != result {
                result = replaced
            } else if term.protectsVerbatim {
                protectedTerms[replacement] = nil
            }
        }
        let courseContext = [
            context.course.name,
            context.course.code,
            context.course.domain,
            context.course.roughDescription,
            context.course.lecturerNames.first,
            context.course.lecturerAccent?.displayName,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
        let recentContext = context.phase != .live
            ? context.recentSourceText.suffix(4).compactMap(cleanContext)
            : []
        return TranslateGemmaPreparedInput(
            text: result,
            protectedTerms: protectedTerms,
            courseContext: context.phase != .live && !courseContext.isEmpty
                ? courseContext
                : nil,
            recentContext: recentContext
        )
    }

    private static func cleanContext(_ text: String) -> String? {
        let text = text
            .replacingOccurrences(of: "<<<", with: "")
            .replacingOccurrences(of: ">>>", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return String(text.prefix(320))
    }

    private static func treatsPaperAsCourse(
        text: String,
        context: TranslationContext
    ) -> Bool {
        let text = text.lowercased()
        if ["research paper", "write a paper", "submit a paper", "published paper"]
            .contains(where: text.contains) {
            return false
        }
        if ["teaching a paper", "second year paper", "paper is worth", "papers are worth"]
            .contains(where: text.contains) {
            return true
        }
        let surrounding = ([text, context.course.name] + context.recentSourceText)
            .joined(separator: " ")
            .lowercased()
        return ["lecture", "assignment", "credits", "tutorial", "lab session", "week "]
            .contains(where: surrounding.contains)
            && ["this paper", "in this paper", "the paper"]
                .contains(where: text.contains)
    }

    private static func hasSoftwareContext(
        text: String,
        context: TranslationContext
    ) -> Bool {
        let surrounding = ([text, context.course.name] + context.recentSourceText)
            .joined(separator: " ")
            .lowercased()
        return [
            "code", "coding", "compiler", "kotlin", "swift", "android",
            "function", "project", "llm", "prompt", "development",
        ].contains(where: surrounding.contains)
    }

    private static func replacingWholeTerm(
        _ source: String,
        with replacement: String,
        in text: String
    ) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])"
            + NSRegularExpression.escapedPattern(for: source)
            + "(?![\\p{L}\\p{N}])"
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    private static func shouldProtectRecognitionTerm(_ term: String) -> Bool {
        if term.contains(where: \.isNumber) { return true }
        let words = term.split(whereSeparator: \.isWhitespace)
        return words.contains { word in
            let letters = word.filter(\.isLetter)
            guard letters.count >= 2 else { return false }
            if letters.allSatisfy(\.isUppercase) { return true }
            return word.dropFirst().contains(where: \.isUppercase)
        }
    }

}

enum TranslateGemmaPromptBuilder {
    static func make(_ input: TranslateGemmaPreparedInput) -> String {
        return """
        <<<source>>>English<<<target>>>Simplified Chinese<<<text>>>
        \(input.text)
        """
    }
}

enum TranslateGemmaOutputProcessor {
    private static let numberExpression = try! NSRegularExpression(
        pattern: #"\b\d+(?:[.:]\d+)*\b"#
    )
    private static let sourceNegationExpression = try! NSRegularExpression(
        pattern: #"\b(?:no|not|never|without|cannot|can't|don't|doesn't|didn't|isn't|aren't|wasn't|weren't|won't|shouldn't|mustn't)\b"#,
        options: [.caseInsensitive]
    )
    private static let sourceRequirementExpression = try! NSRegularExpression(
        pattern: #"\b(?:must|required to|have to|has to)\b"#,
        options: [.caseInsensitive]
    )
    private static let sourceRecommendationExpression = try! NSRegularExpression(
        pattern: #"\b(?:should|need to|needs to)\b"#,
        options: [.caseInsensitive]
    )

    static func process(
        _ response: String,
        sourceText: String,
        preparedInput: TranslateGemmaPreparedInput
    ) throws -> String {
        var translation = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else {
            throw TranslateGemmaError.emptyResponse
        }

        let protectedTerms = preparedInput.protectedTerms.sorted {
            $0.key.count > $1.key.count
        }
        for (placeholder, term) in protectedTerms {
            guard translation.range(of: placeholder, options: .caseInsensitive) != nil else {
                throw TranslateGemmaError.qualityRejected("专有名词缺失：\(term)")
            }
            translation = translation.replacingOccurrences(
                of: placeholder,
                with: term,
                options: .caseInsensitive
            )
        }

        let sourceNumbers = numberTokens(in: sourceText)
        guard sourceNumbers.allSatisfy({ token in
            containsEquivalentNumber(token, in: translation)
        }) else {
            throw TranslateGemmaError.qualityRejected("数字信息缺失")
        }
        guard !containsSourceNegation(sourceText)
                || ["不", "没", "无", "未", "别", "勿", "禁止", "不能", "不会"]
                    .contains(where: translation.contains) else {
            throw TranslateGemmaError.qualityRejected("否定信息缺失")
        }
        guard !contains(sourceRequirementExpression, in: sourceText)
                || ["必须", "务必", "需要", "不得不", "要求"]
                    .contains(where: translation.contains) else {
            throw TranslateGemmaError.qualityRejected("强制要求语气缺失")
        }
        guard !contains(sourceRecommendationExpression, in: sourceText)
                || ["应", "应该", "建议", "需要"]
                    .contains(where: translation.contains) else {
            throw TranslateGemmaError.qualityRejected("建议语气缺失")
        }

        let simplified = translation.applyingTransform(
            StringTransform("Traditional-Simplified"),
            reverse: false
        ) ?? translation
        return simplified.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func numberTokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return numberExpression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func containsSourceNegation(_ text: String) -> Bool {
        contains(sourceNegationExpression, in: text)
    }

    private static func contains(_ expression: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }

    private static func containsEquivalentNumber(_ token: String, in text: String) -> Bool {
        if text.range(of: token) != nil { return true }
        guard token.allSatisfy(\.isNumber), let value = Int(token) else { return false }
        let forms = [chineseCardinal(value), chineseDigitSequence(token)].compactMap { $0 }
        return forms.contains { !$0.isEmpty && text.contains($0) }
    }

    private static func chineseDigitSequence(_ token: String) -> String? {
        let digits = Array("零一二三四五六七八九")
        var result = ""
        for character in token {
            guard let value = character.wholeNumberValue else { return nil }
            result.append(digits[value])
        }
        return result
    }

    private static func chineseCardinal(_ value: Int) -> String? {
        guard (0...9_999).contains(value) else { return nil }
        if value == 0 { return "零" }

        let digits = Array("零一二三四五六七八九")
        let units = ["", "十", "百", "千"]
        var remaining = value
        var position = 0
        var pieces: [String] = []
        var needsZero = false

        while remaining > 0 {
            let digit = remaining % 10
            if digit == 0 {
                if !pieces.isEmpty { needsZero = true }
            } else {
                if needsZero {
                    pieces.append("零")
                    needsZero = false
                }
                pieces.append(units[position])
                pieces.append(String(digits[digit]))
            }
            remaining /= 10
            position += 1
        }
        var result = pieces.reversed().joined()
        if result.hasPrefix("一十") {
            result.removeFirst()
        }
        return result
    }
}

enum TranslateGemmaError: LocalizedError, Equatable {
    case notReady
    case emptyResponse
    case qualityRejected(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "高质量本地翻译模型尚未预热"
        case .emptyResponse:
            return "高质量本地翻译没有返回结果"
        case let .qualityRejected(reason):
            return "高质量本地翻译未通过检查：\(reason)"
        }
    }
}
