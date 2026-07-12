import ClassBridgeCore
import Foundation
import HuggingFace
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
        let preparedText = TranslateGemmaInputBuilder.make(
            text: text,
            context: context
        )

        let maximumTokens = min(
            320,
            max(64, preparedText.split(whereSeparator: \.isWhitespace).count * 4)
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
            \(preparedText)
            """
        )
        let translation = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else {
            throw TranslateGemmaError.emptyResponse
        }
        return translation
    }

    private static var localModelURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["LECCUE_TRANSLATION_MODEL_PATH"],
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static var modelCacheURL: URL {
        if let path = ProcessInfo.processInfo.environment["LECCUE_MODEL_CACHE_PATH"],
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ClassBridge", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("HuggingFace", isDirectory: true)
    }
}

enum TranslateGemmaInputBuilder {
    private struct ReplacementTerm {
        var source: String
        var target: String
    }

    static func make(text: String, context: TranslationContext) -> String {
        var terms = context.approvedTerms.flatMap { term in
            [term.source] + term.aliases
        }.compactMap { source -> ReplacementTerm? in
            guard let approved = context.approvedTerms.first(where: {
                $0.source == source || $0.aliases.contains(source)
            }) else { return nil }
            let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = approved.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !target.isEmpty else { return nil }
            return ReplacementTerm(source: source, target: target)
        }

        terms.append(contentsOf: (context.course.recognitionTerms ?? []).compactMap { term in
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            return term.isEmpty ? nil : ReplacementTerm(source: term, target: term)
        })
        terms.sort { $0.source.count > $1.source.count }

        var result = text
        var seen: Set<String> = []
        for term in terms {
            let key = term.source.lowercased()
            guard seen.insert(key).inserted else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])"
                + NSRegularExpression.escapedPattern(for: term.source)
                + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: term.target)
            )
        }
        return result
    }
}

enum TranslateGemmaError: LocalizedError, Equatable {
    case notReady
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "高质量本地翻译模型尚未预热"
        case .emptyResponse:
            return "高质量本地翻译没有返回结果"
        }
    }
}
