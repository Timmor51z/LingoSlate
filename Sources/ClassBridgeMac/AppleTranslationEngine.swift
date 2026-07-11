import ClassBridgeCore
import Combine
import Foundation
import Translation

@MainActor
protocol AppleTranslationSessionProtocol: AnyObject {
    func prepare() async throws
    func translateText(_ text: AttributedString) async throws -> String
    func cancelPreparation()
}

@MainActor
final class AppleTranslationEngine: ObservableObject, TranslationEngine {
    enum State: Equatable {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    nonisolated let identifier = "apple-translation"

    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published private(set) var state: State = .idle

    private let serialGate = TranslationSerialGate()
    private var session: (any AppleTranslationSessionProtocol)?
    private var activeRunID: UUID?
    private var readinessWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var isReady: Bool {
        state == .ready
    }

    var statusLabel: String {
        switch state {
        case .idle:
            return "翻译待命"
        case .preparing:
            return "正在准备翻译"
        case .ready:
            return "本地翻译"
        case .failed:
            return "翻译未就绪"
        }
    }

    var statusIcon: String {
        switch state {
        case .idle:
            return "character.bubble"
        case .preparing:
            return "arrow.triangle.2.circlepath"
        case .ready:
            return "character.bubble.fill"
        case .failed:
            return "exclamationmark.bubble"
        }
    }

    func activate(retryIfFailed: Bool = false) {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "zh-Hans")

        switch state {
        case .idle:
            state = .preparing
            if var configuration {
                configuration.invalidate()
                self.configuration = configuration
            } else {
                configuration = Self.makeConfiguration(source: source, target: target)
            }
        case .failed:
            guard retryIfFailed else { return }
            state = .preparing
            if var configuration {
                configuration.invalidate()
                self.configuration = configuration
            } else {
                configuration = Self.makeConfiguration(source: source, target: target)
            }
        case .preparing, .ready:
            break
        }
    }

    func prepare(timeout: TimeInterval = 120) async -> Bool {
        await waitUntilReady(timeout: timeout, retryIfFailed: true)
    }

    func run(systemSession: TranslationSession) async {
        await run(session: SystemAppleTranslationSession(session: systemSession))
    }

    func run(session: any AppleTranslationSessionProtocol) async {
        let runID = UUID()
        activeRunID = runID
        self.session = session
        state = .preparing

        do {
            try await session.prepare()
            try Task.checkCancellation()
            guard activeRunID == runID else { return }

            state = .ready
            resolveReadinessWaiters(with: true)

            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3_600))
            }
        } catch is CancellationError {
            if activeRunID == runID {
                state = .idle
                resolveReadinessWaiters(with: false)
            }
        } catch {
            if activeRunID == runID {
                state = .failed(error.localizedDescription)
                resolveReadinessWaiters(with: false)
            }
        }

        if activeRunID == runID {
            activeRunID = nil
            self.session = nil
        }
    }

    func cancelPreparation() {
        guard state == .preparing else { return }
        session?.cancelPreparation()
        resolveReadinessWaiters(with: false)
    }

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        guard await waitUntilReady(timeout: 12, retryIfFailed: false), let session else {
            throw AppleTranslationEngineError.notReady
        }

        await serialGate.acquire()
        do {
            try Task.checkCancellation()
            let input = AppleTranslationInputBuilder.make(text: text, context: context)
            let translation = try await session.translateText(input)
            await serialGate.release()
            return translation.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await serialGate.release()
            throw error
        }
    }

    private static func makeConfiguration(
        source: Locale.Language,
        target: Locale.Language
    ) -> TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(
                source: source,
                target: target,
                preferredStrategy: .highFidelity
            )
        }
        return TranslationSession.Configuration(source: source, target: target)
    }

    private func waitUntilReady(
        timeout: TimeInterval,
        retryIfFailed: Bool
    ) async -> Bool {
        activate(retryIfFailed: retryIfFailed)
        if state == .ready { return true }
        if case .failed = state { return false }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                readinessWaiters[waiterID] = continuation

                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0.1, timeout)))
                    self?.resolveReadinessWaiter(waiterID, with: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveReadinessWaiter(waiterID, with: false)
            }
        }
    }

    private func resolveReadinessWaiter(_ id: UUID, with value: Bool) {
        readinessWaiters.removeValue(forKey: id)?.resume(returning: value)
    }

    private func resolveReadinessWaiters(with value: Bool) {
        let waiters = readinessWaiters.values
        readinessWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }
}

enum AppleTranslationEngineError: LocalizedError, Equatable {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "本地翻译语言包尚未就绪"
        }
    }
}

@MainActor
private final class SystemAppleTranslationSession: AppleTranslationSessionProtocol {
    // TranslationSession lacks a Sendable annotation in the macOS 15 SDK.
    // Access remains serialized by AppleTranslationEngine's gate.
    nonisolated(unsafe) private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func prepare() async throws {
        try await session.prepareTranslation()
    }

    func translateText(_ text: AttributedString) async throws -> String {
        if #available(macOS 26.4, *) {
            return try await session.translate(text).targetText
        }
        return try await session.translate(String(text.characters)).targetText
    }

    func cancelPreparation() {
        if #available(macOS 26.0, *) {
            session.cancel()
        }
    }
}

private enum AppleTranslationInputBuilder {
    private struct ProtectedTerm {
        var source: String
        var target: String
    }

    private struct Replacement {
        var range: Range<String.Index>
        var target: String
    }

    static func make(text: String, context: TranslationContext) -> AttributedString {
        let normalized = normalize(text)
        guard #available(macOS 26.4, *) else {
            return AttributedString(normalized)
        }

        let replacements = protectedReplacements(in: normalized, context: context)
        guard !replacements.isEmpty else {
            return AttributedString(normalized)
        }

        var result = AttributedString()
        var cursor = normalized.startIndex
        for replacement in replacements {
            result.append(AttributedString(String(normalized[cursor..<replacement.range.lowerBound])))
            var protectedText = AttributedString(replacement.target)
            protectedText.translation.skipsTranslation = true
            result.append(protectedText)
            cursor = replacement.range.upperBound
        }
        result.append(AttributedString(String(normalized[cursor...])))
        return result
    }

    private static func normalize(_ text: String) -> String {
        var normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard let last = normalized.last else { return normalized }
        if !".!?;:".contains(last) {
            normalized.append(".")
        }
        return normalized
    }

    private static func protectedReplacements(
        in text: String,
        context: TranslationContext
    ) -> [Replacement] {
        let terms = protectedTerms(context: context)
        var replacements: [Replacement] = []

        for term in terms.sorted(by: { $0.source.count > $1.source.count }) {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(
                    of: term.source,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchStart..<text.endIndex
                  ) {
                if hasWordBoundaries(range, in: text),
                   !replacements.contains(where: { $0.range.overlaps(range) }) {
                    replacements.append(Replacement(range: range, target: term.target))
                }
                searchStart = range.upperBound
            }
        }

        return replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func protectedTerms(context: TranslationContext) -> [ProtectedTerm] {
        var terms: [ProtectedTerm] = []
        var seen: Set<String> = []

        func append(source: String, target: String) {
            let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !target.isEmpty else { return }
            let key = source.lowercased()
            guard seen.insert(key).inserted else { return }
            terms.append(ProtectedTerm(source: source, target: target))
        }

        for term in context.approvedTerms {
            append(source: term.source, target: term.target)
            for alias in term.aliases {
                append(source: alias, target: term.target)
            }
        }

        if let courseCode = context.course.code {
            append(source: courseCode, target: courseCode)
        }
        for term in context.course.recognitionTerms ?? [] where shouldPreserveVerbatim(term) {
            append(source: term, target: term)
        }
        return terms
    }

    private static func shouldPreserveVerbatim(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        let isAcronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
        let hasInternalUppercase = term.dropFirst().contains(where: \.isUppercase)
        return isAcronym || hasInternalUppercase || term.contains(where: \.isNumber)
    }

    private static func hasWordBoundaries(
        _ range: Range<String.Index>,
        in text: String
    ) -> Bool {
        let leftIsWord = range.lowerBound > text.startIndex
            && text[text.index(before: range.lowerBound)].isLetterOrNumber
        let rightIsWord = range.upperBound < text.endIndex
            && text[range.upperBound].isLetterOrNumber
        return !leftIsWord && !rightIsWord
    }
}

private extension Character {
    var isLetterOrNumber: Bool {
        isLetter || isNumber
    }
}

private actor TranslationSerialGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}
