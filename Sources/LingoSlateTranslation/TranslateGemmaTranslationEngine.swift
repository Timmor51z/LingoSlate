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
            to: """
            <<<source>>>English<<<target>>>Simplified Chinese<<<text>>>
            \(preparedInput.text)
            """
        )
        return try TranslateGemmaOutputProcessor.process(
            response,
            sourceText: text,
            preparedInput: preparedInput
        )
    }

    public func release() {
        modelContainer = nil
        Memory.clearCache()
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
}

enum TranslateGemmaInputBuilder {
    private struct ReplacementTerm {
        var source: String
        var target: String
        var protectsVerbatim: Bool
    }

    static func make(text: String, context: TranslationContext) -> TranslateGemmaPreparedInput {
        var terms: [ReplacementTerm] = []
        for approved in context.approvedTerms {
            let target = approved.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            let protectsVerbatim = normalized(approved.source) == normalized(target)
            terms.append(contentsOf: ([approved.source] + approved.aliases).compactMap { source in
                let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { return nil }
                return ReplacementTerm(
                    source: source,
                    target: target,
                    protectsVerbatim: protectsVerbatim
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
        return TranslateGemmaPreparedInput(text: result, protectedTerms: protectedTerms)
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

    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.compactMap { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : nil
        }.joined()
    }
}

enum TranslateGemmaOutputProcessor {
    private static let numberExpression = try! NSRegularExpression(
        pattern: #"\b\d+(?:[.:]\d+)*\b"#
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
