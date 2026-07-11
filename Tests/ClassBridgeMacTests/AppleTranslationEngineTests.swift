import ClassBridgeCore
import XCTest
@testable import ClassBridgeMac

final class AppleTranslationEngineTests: XCTestCase {
    @MainActor
    func testPreparationAndTranslationUseTheAttachedSession() async throws {
        let engine = AppleTranslationEngine()
        let session = TestAppleTranslationSession()
        let preparation = Task { await engine.prepare(timeout: 1) }
        let runner = Task { await engine.run(session: session) }

        let isReady = await preparation.value
        XCTAssertTrue(isReady)
        XCTAssertEqual(engine.state, .ready)

        let translation = try await engine.translate(
            "The event loop schedules callbacks.",
            context: TranslationContext(course: Course(name: "Concurrency"), recentSourceText: [])
        )
        XCTAssertEqual(translation, "译文：The event loop schedules callbacks.")

        runner.cancel()
        await runner.value
    }

    @MainActor
    func testConcurrentRequestsAreSerialized() async throws {
        let engine = AppleTranslationEngine()
        let session = TestAppleTranslationSession(translationDelay: .milliseconds(30))
        let preparation = Task { await engine.prepare(timeout: 1) }
        let runner = Task { await engine.run(session: session) }
        let isReady = await preparation.value
        XCTAssertTrue(isReady)

        async let first = engine.translate(
            "First sentence.",
            context: TranslationContext(course: Course(name: "Testing"), recentSourceText: [])
        )
        async let second = engine.translate(
            "Second sentence.",
            context: TranslationContext(course: Course(name: "Testing"), recentSourceText: [])
        )
        _ = try await [first, second]

        XCTAssertEqual(session.maximumConcurrentTranslations, 1)
        runner.cancel()
        await runner.value
    }

    @MainActor
    func testPreparationFailureIsReportedWithoutAPlaceholderTranslation() async {
        let engine = AppleTranslationEngine()
        let session = TestAppleTranslationSession(preparationError: TestError.unavailable)
        let preparation = Task { await engine.prepare(timeout: 1) }
        let runner = Task { await engine.run(session: session) }

        let isReady = await preparation.value
        XCTAssertFalse(isReady)
        XCTAssertEqual(engine.state, .failed("Translation unavailable"))

        do {
            _ = try await engine.translate(
                "This should keep the English subtitle.",
                context: TranslationContext(course: Course(name: "Testing"), recentSourceText: [])
            )
            XCTFail("Expected translation to remain unavailable")
        } catch {
            XCTAssertEqual(error as? AppleTranslationEngineError, .notReady)
        }
        XCTAssertEqual(engine.state, .failed("Translation unavailable"))

        runner.cancel()
        await runner.value
    }
}

@MainActor
private final class TestAppleTranslationSession: AppleTranslationSessionProtocol {
    private let preparationError: Error?
    private let translationDelay: Duration
    private var concurrentTranslations = 0
    private(set) var maximumConcurrentTranslations = 0

    init(
        preparationError: Error? = nil,
        translationDelay: Duration = .zero
    ) {
        self.preparationError = preparationError
        self.translationDelay = translationDelay
    }

    func prepare() async throws {
        if let preparationError {
            throw preparationError
        }
    }

    func translateText(_ text: String) async throws -> String {
        concurrentTranslations += 1
        maximumConcurrentTranslations = max(
            maximumConcurrentTranslations,
            concurrentTranslations
        )
        if translationDelay > .zero {
            try await Task.sleep(for: translationDelay)
        }
        concurrentTranslations -= 1
        return "译文：\(text)"
    }

    func cancelPreparation() {}
}

private enum TestError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Translation unavailable"
    }
}
