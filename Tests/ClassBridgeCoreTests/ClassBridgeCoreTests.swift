import XCTest
@testable import ClassBridgeCore

final class ClassBridgeCoreTests: XCTestCase {
    func testCourseNeedsOnlyAName() {
        XCTAssertFalse(Course(name: "   ").isReadyToStart)
        XCTAssertTrue(Course(name: "Mobile Computing").isReadyToStart)
    }

    func testRecognitionConfigurationUsesOnlyApprovedTerms() {
        let approved = GlossaryTerm(
            source: "event loop",
            target: "事件循环",
            origin: .user,
            isApproved: true
        )
        let suggestion = GlossaryTerm(
            source: "callback",
            target: "回调",
            origin: .sessionSuggestion,
            confidence: 0.7,
            isApproved: false
        )

        let configuration = RecognitionConfiguration(
            course: Course(name: "Software Architecture"),
            approvedTerms: [approved, suggestion]
        )

        XCTAssertEqual(configuration.approvedTerms, [approved])
    }

    func testSessionStateMachineRejectsInvalidTransition() async throws {
        let machine = SessionStateMachine()

        do {
            try await machine.transition(to: .running)
            XCTFail("Expected an invalid transition error")
        } catch let error as SessionTransitionError {
            XCTAssertEqual(
                error,
                .invalidTransition(from: .idle, to: .running)
            )
        }

        try await machine.transition(to: .preparing)
        try await machine.transition(to: .running)
        let runningState = await machine.currentState()
        XCTAssertEqual(runningState, .running)
    }

    func testPipelineKeepsProvisionalThenTranslatesFinalSegment() async {
        let course = Course(name: "Concurrency")
        let pipeline = SubtitlePipeline(
            course: course,
            translationEngine: TestTranslationEngine()
        )
        let id = UUID()

        await pipeline.consume(
            .provisional(
                id: id,
                text: "The event loop",
                startTime: 0,
                endTime: 1,
                provider: "test"
            )
        )

        var snapshot = await pipeline.currentSnapshot()
        XCTAssertEqual(snapshot.provisionalSegment?.sourceText, "The event loop")
        XCTAssertTrue(snapshot.finalSegments.isEmpty)

        await pipeline.consume(
            .final(
                id: id,
                text: "The event loop schedules callbacks.",
                startTime: 0,
                endTime: 2,
                speaker: nil,
                provider: "test"
            )
        )

        snapshot = await pipeline.currentSnapshot()
        XCTAssertNil(snapshot.provisionalSegment)
        XCTAssertEqual(snapshot.finalSegments.count, 1)
        XCTAssertEqual(snapshot.finalSegments[0].translatedText, "译文：The event loop schedules callbacks.")
        XCTAssertEqual(snapshot.finalSegments[0].state, .translated)
    }

    func testSessionStoreRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassBridgeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directoryURL: directory)
        let document = SessionDocument(
            configuration: SessionConfiguration(
                course: Course(name: "Advanced Databases")
            ),
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 2,
                    sourceText: "Transactions provide atomicity.",
                    translatedText: "事务提供原子性。",
                    state: .translated,
                    provider: "test"
                )
            ]
        )

        try await store.save(document)
        let loaded = try await store.load(id: document.id)
        let allDocuments = try await store.list()

        XCTAssertEqual(loaded.id, document.id)
        XCTAssertEqual(loaded.configuration, document.configuration)
        XCTAssertEqual(loaded.segments, document.segments)
        XCTAssertEqual(loaded.markers, document.markers)
        XCTAssertEqual(
            loaded.startedAt.timeIntervalSince1970,
            document.startedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(allDocuments.map(\.id), [document.id])
    }
}

private struct TestTranslationEngine: TranslationEngine {
    let identifier = "test"

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        "译文：\(text)"
    }
}
