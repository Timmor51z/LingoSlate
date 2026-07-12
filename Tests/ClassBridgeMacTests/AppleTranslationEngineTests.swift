import ClassBridgeCore
import XCTest
@testable import ClassBridgeTranslation
@testable import ClassBridgeMac

final class AppleTranslationEngineTests: XCTestCase {
    func testTranslateGemmaInputUsesApprovedGlossaryAndProtectsRecognitionTerms() {
        let input = TranslateGemmaInputBuilder.make(
            text: "Papers use Moodle; paperwork does not mean a paper.",
            context: TranslationContext(
                course: Course(name: "Orientation", recognitionTerms: ["Moodle"]),
                recentSourceText: [],
                approvedTerms: [
                    GlossaryTerm(
                        source: "paper",
                        target: "课程",
                        aliases: ["papers"],
                        origin: .user,
                        isApproved: true
                    ),
                ]
            )
        )

        XCTAssertEqual(input, "课程 use Moodle; paperwork does not mean a 课程.")
    }

    func testTranslateGemmaLocalModelSmokeWhenConfigured() async throws {
        guard ProcessInfo.processInfo.environment["LECCUE_TRANSLATION_MODEL_PATH"] != nil else {
            throw XCTSkip("Set LECCUE_TRANSLATION_MODEL_PATH to run the local model smoke test")
        }

        let engine = TranslateGemmaTranslationEngine()
        let isReady = await engine.prepare()
        XCTAssertTrue(isReady)

        let translation = try await engine.translate(
            "Welcome to the Division. This information is important for your success.",
            context: TranslationContext(
                course: Course(name: "STEAM College Orientation"),
                recentSourceText: []
            )
        )

        XCTAssertTrue(translation.contains("欢迎"), translation)
        XCTAssertTrue(translation.contains("重要"), translation)
    }

    @MainActor
    func testActivationPrefersHighFidelityTranslationOnCurrentSystems() {
        let engine = AppleTranslationEngine()

        engine.activate()

        if #available(macOS 26.4, *) {
            XCTAssertEqual(engine.configuration?.preferredStrategy, .highFidelity)
        }
    }

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
    func testTranslationNormalizesFragmentsAndProtectsCourseTerms() async throws {
        let engine = AppleTranslationEngine()
        let session = TestAppleTranslationSession()
        let preparation = Task { await engine.prepare(timeout: 1) }
        let runner = Task { await engine.run(session: session) }
        let isReady = await preparation.value
        XCTAssertTrue(isReady)

        _ = try await engine.translate(
            "  Welcome   to STEAM and MyWaikato  ",
            context: TranslationContext(
                course: Course(
                    name: "Orientation",
                    recognitionTerms: ["STEAM", "MyWaikato"]
                ),
                recentSourceText: []
            )
        )

        XCTAssertEqual(
            session.translatedInputs.map { String($0.characters) },
            ["Welcome to STEAM and MyWaikato."]
        )
        if #available(macOS 26.4, *) {
            let protectedText = session.translatedInputs[0].runs.compactMap { run -> String? in
                guard run.translation.skipsTranslation == true else { return nil }
                return String(session.translatedInputs[0][run.range].characters)
            }
            XCTAssertEqual(protectedText, ["STEAM", "MyWaikato"])
        }

        runner.cancel()
        await runner.value
    }

    @MainActor
    func testApprovedGlossaryUsesPreferredChineseTerm() async throws {
        let engine = AppleTranslationEngine()
        let session = TestAppleTranslationSession()
        let preparation = Task { await engine.prepare(timeout: 1) }
        let runner = Task { await engine.run(session: session) }
        let isReady = await preparation.value
        XCTAssertTrue(isReady)

        _ = try await engine.translate(
            "A finite-state machine handles transitions.",
            context: TranslationContext(
                course: Course(name: "Software Architecture"),
                recentSourceText: [],
                approvedTerms: [
                    GlossaryTerm(
                        source: "finite-state machine",
                        target: "有限状态机",
                        origin: .user,
                        isApproved: true
                    ),
                ]
            )
        )

        XCTAssertEqual(
            session.translatedInputs.map { String($0.characters) },
            ["A 有限状态机 handles transitions."]
        )

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
    private(set) var translatedInputs: [AttributedString] = []

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

    func translateText(_ text: AttributedString) async throws -> String {
        concurrentTranslations += 1
        translatedInputs.append(text)
        maximumConcurrentTranslations = max(
            maximumConcurrentTranslations,
            concurrentTranslations
        )
        if translationDelay > .zero {
            try await Task.sleep(for: translationDelay)
        }
        concurrentTranslations -= 1
        return "译文：\(String(text.characters))"
    }

    func cancelPreparation() {}
}

private enum TestError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Translation unavailable"
    }
}
