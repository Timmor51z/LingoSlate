import ClassBridgeCore
import XCTest
@testable import ClassBridgeTranslation
@testable import ClassBridgeMac

final class AppleTranslationEngineTests: XCTestCase {
    func testTranslateGemmaInputUsesApprovedGlossaryAndProtectsRecognitionTerms() {
        let input = TranslateGemmaInputBuilder.make(
            text: "Papers use MyWaikato and STEM; paperwork does not mean a paper.",
            context: TranslationContext(
                course: Course(name: "Orientation", recognitionTerms: ["STEM"]),
                recentSourceText: [],
                approvedTerms: [
                    GlossaryTerm(
                        source: "paper",
                        target: "课程",
                        aliases: ["papers"],
                        origin: .user,
                        isApproved: true
                    ),
                    GlossaryTerm(
                        source: "MyWaikato",
                        target: "MyWaikato",
                        origin: .officialCourseSource,
                        isApproved: true
                    ),
                ]
            )
        )

        XCTAssertTrue(input.text.hasPrefix("课程 use "))
        XCTAssertTrue(input.text.hasSuffix("; paperwork does not mean a 课程."))
        XCTAssertEqual(Set(input.protectedTerms.values), ["MyWaikato", "STEM"])
        XCTAssertFalse(input.text.contains("MyWaikato"))
        XCTAssertFalse(input.text.contains("STEM"))
    }

    func testTranslateGemmaOutputRestoresTermsNumbersAndSimplifiedChinese() throws {
        let translation = try TranslateGemmaOutputProcessor.process(
            "我們在 LECCUEPROPER0 上查看 15 個課程。",
            sourceText: "We review 15 papers in MyWaikato.",
            preparedInput: TranslateGemmaPreparedInput(
                text: "We review 15 papers in LECCUEPROPER0.",
                protectedTerms: ["LECCUEPROPER0": "MyWaikato"]
            )
        )

        XCTAssertEqual(translation, "我们在 MyWaikato 上查看 15 个课程。")
    }

    func testTranslateGemmaOutputRejectsMissingProtectedTerm() {
        XCTAssertThrowsError(
            try TranslateGemmaOutputProcessor.process(
                "欢迎使用学生系统。",
                sourceText: "Welcome to MyWaikato.",
                preparedInput: TranslateGemmaPreparedInput(
                    text: "Welcome to LECCUEPROPER0.",
                    protectedTerms: ["LECCUEPROPER0": "MyWaikato"]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TranslateGemmaError,
                .qualityRejected("专有名词缺失：MyWaikato")
            )
        }
    }

    func testTranslateGemmaOutputRejectsMissingNumber() {
        XCTAssertThrowsError(
            try TranslateGemmaOutputProcessor.process(
                "每门课程都有学分。",
                sourceText: "Each paper is worth 15 credits.",
                preparedInput: TranslateGemmaPreparedInput(
                    text: "Each paper is worth 15 credits.",
                    protectedTerms: [:]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TranslateGemmaError,
                .qualityRejected("数字信息缺失")
            )
        }
    }

    func testTranslateGemmaOutputAcceptsEquivalentChineseNumbers() throws {
        let translation = try TranslateGemmaOutputProcessor.process(
            "每门课程有十五学分，三门共四十五学分。",
            sourceText: "Each paper is worth 15 credits, so three papers are worth 45.",
            preparedInput: TranslateGemmaPreparedInput(
                text: "Each paper is worth 15 credits, so three papers are worth 45.",
                protectedTerms: [:]
            )
        )

        XCTAssertEqual(translation, "每门课程有十五学分，三门共四十五学分。")
    }

    func testTranslateGemmaOutputRestoresOverlappingPlaceholderPrefixes() throws {
        let translation = try TranslateGemmaOutputProcessor.process(
            "LECCUEPROPER10 和 LECCUEPROPER1",
            sourceText: "MyWaikato and STEM",
            preparedInput: TranslateGemmaPreparedInput(
                text: "LECCUEPROPER10 and LECCUEPROPER1",
                protectedTerms: [
                    "LECCUEPROPER1": "STEM",
                    "LECCUEPROPER10": "MyWaikato",
                ]
            )
        )

        XCTAssertEqual(translation, "MyWaikato 和 STEM")
    }

    func testTranslateGemmaLocalModelSmokeWhenConfigured() async throws {
        guard ProcessInfo.processInfo.environment["LECCUE_TRANSLATION_MODEL_PATH"] != nil else {
            throw XCTSkip("Set LECCUE_TRANSLATION_MODEL_PATH to run the local model smoke test")
        }

        let engine = TranslateGemmaTranslationEngine()
        let isReady = await engine.prepare()
        XCTAssertTrue(isReady)

        let translation = try await engine.translate(
            "Welcome to STEM. Open My Way Kato. This information is important. Each paper is worth 15 credits.",
            context: TranslationContext(
                course: Course(
                    name: "STEM College Orientation",
                    recognitionTerms: ["STEM"]
                ),
                recentSourceText: [],
                approvedTerms: [
                    GlossaryTerm(
                        source: "MyWaikato",
                        target: "MyWaikato",
                        aliases: ["My Way Kato"],
                        origin: .officialCourseSource,
                        isApproved: true
                    ),
                ]
            )
        )

        XCTAssertTrue(translation.contains("欢迎"), translation)
        XCTAssertTrue(translation.contains("重要"), translation)
        XCTAssertTrue(translation.contains("STEM"), translation)
        XCTAssertTrue(translation.contains("MyWaikato"), translation)
        XCTAssertTrue(translation.contains("15"), translation)
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
