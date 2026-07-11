import ClassBridgeCore
import Combine
import Foundation
import Translation

@MainActor
protocol AppleTranslationSessionProtocol: AnyObject {
    func prepare() async throws
    func translateText(_ text: String) async throws -> String
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
                configuration = TranslationSession.Configuration(
                    source: source,
                    target: target
                )
            }
        case .failed:
            guard retryIfFailed else { return }
            state = .preparing
            if var configuration {
                configuration.invalidate()
                self.configuration = configuration
            } else {
                configuration = TranslationSession.Configuration(
                    source: source,
                    target: target
                )
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
            let translation = try await session.translateText(text)
            await serialGate.release()
            return translation.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await serialGate.release()
            throw error
        }
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

    func translateText(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }

    func cancelPreparation() {
        if #available(macOS 26.0, *) {
            session.cancel()
        }
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
