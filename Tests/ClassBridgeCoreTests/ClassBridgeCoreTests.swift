import XCTest
@testable import ClassBridgeAudio
@testable import ClassBridgeCore

final class ClassBridgeCoreTests: XCTestCase {
    func testNewZealandAcademicGlossaryUsesPhrasesWithoutAmbiguousSingleWords() {
        let terms = RegionalAcademicGlossary.approvedTerms(
            for: UserProfile(schoolName: "University of Waikato", regionCode: "NZ")
        )

        XCTAssertTrue(terms.allSatisfy(\.isApproved))
        XCTAssertTrue(terms.contains { $0.source == "paper outline" && $0.target == "课程大纲" })
        XCTAssertTrue(terms.contains { $0.source == "attend the lab" && $0.target == "参加实验课" })
        XCTAssertFalse(terms.contains { $0.source == "paper" || $0.source == "lab" })
        XCTAssertTrue(
            RegionalAcademicGlossary.approvedTerms(
                for: UserProfile(regionCode: "US")
            ).isEmpty
        )
    }

    func testAdaptiveGainRaisesQuietSpeechWithoutClipping() {
        var processor = AdaptiveGainProcessor()
        let frame = AudioFrame(
            samples: [Float](repeating: 0.01, count: 3_200),
            sampleRate: 16_000,
            capturedAt: 42
        )

        var processed = frame
        for _ in 0..<10 {
            processed = processor.process(frame)
        }

        XCTAssertGreaterThan(processor.currentGainDecibels, 10)
        XCTAssertLessThanOrEqual(processed.samples.map(abs).max() ?? 1, 0.89)
        XCTAssertEqual(processed.capturedAt, 42)
        XCTAssertEqual(processed.sampleRate, 16_000)
    }

    func testAdaptiveGainDoesNotChaseSilence() {
        var processor = AdaptiveGainProcessor()
        let silence = AudioFrame(
            samples: [Float](repeating: 0, count: 3_200),
            sampleRate: 16_000,
            capturedAt: 0
        )

        _ = processor.process(silence)

        XCTAssertEqual(processor.currentGain, 1, accuracy: 0.0001)
    }

    func testAdaptiveGainLimiterProtectsSuddenPeaks() {
        var processor = AdaptiveGainProcessor()
        let quiet = AudioFrame(
            samples: [Float](repeating: 0.01, count: 3_200),
            sampleRate: 16_000,
            capturedAt: 0
        )
        for _ in 0..<10 {
            _ = processor.process(quiet)
        }

        let loud = AudioFrame(
            samples: [0.8, -0.8, 0.7, -0.7],
            sampleRate: 16_000,
            capturedAt: 1
        )
        let processed = processor.process(loud)

        XCTAssertLessThanOrEqual(processed.samples.map(abs).max() ?? 1, 0.89)
        XCTAssertLessThanOrEqual(processor.currentGain, 0.89 / 0.8 + 0.0001)
    }

    func testTranscriptComparisonNormalizesCaseAndPunctuation() {
        XCTAssertEqual(
            TranscriptComparison.normalizedWords(in: "Hello, STEAM! It's 2026."),
            ["hello", "steam", "it", "s", "2026"]
        )
    }

    func testTranscriptComparisonEvaluationTreatsFormattingAsEquivalent() {
        XCTAssertEqual(
            TranscriptComparison.evaluationWords(
                in: "It's 12:00 p.m. and A.I."
            ),
            ["its", "12", "pm", "and", "ai"]
        )
        XCTAssertEqual(
            TranscriptComparison.evaluationWordEditDistance(
                reference: "It's 12:00 p.m. and A.I.",
                hypothesis: "Its 12 pm and AI."
            ),
            0
        )
    }

    func testTranscriptComparisonCanonicalizesDottedAcronyms() {
        XCTAssertEqual(
            TranscriptComparison.acronymTokens(in: "AI A.I. STEM LG01"),
            ["ai", "ai", "stem", "lg01"]
        )
    }

    func testTranscriptComparisonCountsWordOperations() {
        let result = TranscriptComparison.wordErrors(
            reference: "the cat sat",
            hypothesis: "the dog sat there"
        )

        XCTAssertEqual(result.substitutions, 1)
        XCTAssertEqual(result.deletions, 0)
        XCTAssertEqual(result.insertions, 1)
        XCTAssertEqual(result.totalEdits, 2)
        XCTAssertEqual(result.errorRate, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testTranscriptComparisonCalculatesMemoryEfficientWordDistance() {
        XCTAssertEqual(
            TranscriptComparison.wordEditDistance(
                reference: "the cat sat",
                hypothesis: "the dog sat there"
            ),
            2
        )
        XCTAssertEqual(
            TranscriptComparison.wordEditDistance(reference: "", hypothesis: "hello world"),
            2
        )
    }

    func testTranscriptComparisonCriticalTokenRecallUsesCounts() {
        let reference = ["2026", "steam", "steam"]
        let hypothesis = ["2026", "steam"]
        let result = TranscriptComparison.tokenRecall(
            referenceTokens: reference,
            hypothesisTokens: hypothesis
        )

        XCTAssertEqual(result.referenceCount, 3)
        XCTAssertEqual(result.matchedCount, 2)
        XCTAssertEqual(result.recall ?? -1, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testTranscriptComparisonWordCoverageUsesMultisetIntersection() {
        let result = TranscriptComparison.wordCoverage(
            reference: "STEAM class class starts now",
            hypothesis: "Now the STEAM class starts"
        )

        XCTAssertEqual(result.referenceWordCount, 5)
        XCTAssertEqual(result.hypothesisWordCount, 5)
        XCTAssertEqual(result.matchedWordCount, 4)
        XCTAssertEqual(result.recall ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(result.precision ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(result.f1 ?? -1, 0.8, accuracy: 0.0001)
    }

    func testAudioFrameNormalizesInputLevel() {
        let silence = AudioFrame(samples: [0, 0, 0], sampleRate: 16_000, capturedAt: 0)
        let loud = AudioFrame(samples: [1, -1, 1, -1], sampleRate: 16_000, capturedAt: 0)

        XCTAssertEqual(silence.normalizedLevel, 0, accuracy: 0.001)
        XCTAssertEqual(loud.normalizedLevel, 1, accuracy: 0.001)
    }

    func testMicrophoneCaptureRejectsMissingInputDeviceWithoutStartingAudioEngine() async {
        let capture = MicrophoneAudioCapture(inputDeviceIsAvailable: { false })

        do {
            try await capture.start()
            XCTFail("Expected unavailable microphone error")
        } catch let error as MicrophoneCaptureError {
            guard case .unavailable = error else {
                return XCTFail("Expected unavailable, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSessionAudioBufferTracksDurationAndReleasesFrames() async {
        let buffer = SessionAudioBuffer()
        await buffer.append(
            AudioFrame(
                samples: [Float](repeating: 0.1, count: 3_200),
                sampleRate: 16_000,
                capturedAt: 10
            )
        )
        await buffer.append(
            AudioFrame(
                samples: [Float](repeating: 0.1, count: 3_200),
                sampleRate: 16_000,
                capturedAt: 10.2
            )
        )

        let duration = await buffer.duration
        let wasEmpty = await buffer.isEmpty
        await buffer.reset()
        let isEmpty = await buffer.isEmpty

        XCTAssertEqual(duration, 0.4, accuracy: 0.001)
        XCTAssertFalse(wasEmpty)
        XCTAssertTrue(isEmpty)
    }

    func testIncrementalTranscriptCursorReturnsOnlyNewWords() {
        var cursor = IncrementalTranscriptCursor()

        XCTAssertEqual(cursor.uncommittedText(in: "The event loop"), "The event loop")
        cursor.commit("The event loop")
        XCTAssertEqual(
            cursor.uncommittedText(in: "The event loop, schedules callbacks."),
            "schedules callbacks."
        )
    }

    func testIncrementalTranscriptCursorUsesAnchorAfterLeadingRevision() {
        let cursor = IncrementalTranscriptCursor(
            committedTranscript: "The timetable shows every class"
        )

        XCTAssertEqual(
            cursor.uncommittedText(
                in: "Well, the timetable shows every class on campus today"
            ),
            "on campus today"
        )
    }

    func testIncrementalTranscriptCursorUsesWordPositionAfterRevision() {
        let cursor = IncrementalTranscriptCursor(
            committedTranscript: "We use the timetable to find our classes"
        )

        XCTAssertEqual(
            cursor.uncommittedText(
                in: "We use a timetable to find all classes today online"
            ),
            "today online"
        )
    }

    func testIncrementalTranscriptCursorWaitsForShorterRevision() {
        let cursor = IncrementalTranscriptCursor(
            committedTranscript: "The event loop schedules every callback"
        )

        XCTAssertEqual(
            cursor.uncommittedText(in: "The event loop schedules"),
            ""
        )
    }

    func testCourseNeedsOnlyAName() {
        XCTAssertFalse(Course(name: "   ").isReadyToStart)
        XCTAssertTrue(Course(name: "Mobile Computing").isReadyToStart)
    }

    func testUserProfileNormalizesStoredValues() {
        let profile = UserProfile(
            schoolName: "  University of Waikato  ",
            regionCode: " nz "
        )

        XCTAssertEqual(profile.schoolName, "University of Waikato")
        XCTAssertEqual(profile.regionCode, "NZ")
        XCTAssertTrue(profile.hasSchool)
    }

    @MainActor
    func testUserProfileStorePersistsLocally() throws {
        let suiteName = "LecCueTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserProfileStore(
            defaults: defaults,
            storageKey: "profile",
            defaultRegionCode: "NZ"
        )
        store.schoolName = "University of Waikato"
        store.regionCode = "NZ"

        let reloaded = UserProfileStore(
            defaults: defaults,
            storageKey: "profile",
            defaultRegionCode: "US"
        )
        XCTAssertEqual(reloaded.profile, store.profile)
    }

    func testCourseTermSeedsUseCourseAndSchoolContext() {
        let terms = CourseTermSeedBuilder.suggestions(
            courseName: "Mobile Computing and Software Architecture",
            schoolName: "University of Waikato"
        )

        XCTAssertEqual(
            terms,
            [
                "University of Waikato",
                "Mobile Computing",
                "Software Architecture",
            ]
        )
    }

    func testCourseDecodesLegacyDataWithoutRecognitionTerms() throws {
        let data = Data(
            #"""
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "name": "Architecture",
              "lecturerNames": [],
              "targetLanguage": "zh-Hans",
              "contextMaturity": 0
            }
            """#.utf8
        )

        let course = try JSONDecoder().decode(Course.self, from: data)

        XCTAssertNil(course.recognitionTerms)
    }

    func testTranscriptTermNormalizerRepairsCloseCourseTerms() {
        let normalizer = TranscriptTermNormalizer(
            preferredTerms: ["MyWaikato", "Waikato", "Panopto", "Moodle"]
        )

        XCTAssertEqual(
            normalizer.normalize("Open My Way Kato for the Waykato timetable."),
            "Open MyWaikato for the Waikato timetable."
        )
        XCTAssertEqual(
            normalizer.normalize("The mobile lab uses a model."),
            "The mobile lab uses a model."
        )
    }

    func testTranscriptTermNormalizerUsesCourseNameConservatively() {
        let normalizer = TranscriptTermNormalizer(
            course: Course(name: "Mobile Computing and Software Architecture")
        )

        XCTAssertEqual(
            normalizer.normalize("We study software architectur patterns."),
            "We study Software Architecture patterns."
        )
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
        await pipeline.finishPendingTranslations()

        snapshot = await pipeline.currentSnapshot()
        XCTAssertNil(snapshot.provisionalSegment)
        XCTAssertEqual(snapshot.finalSegments.count, 1)
        XCTAssertEqual(snapshot.finalSegments[0].translatedText, "译文：The event loop schedules callbacks.")
        XCTAssertEqual(snapshot.finalSegments[0].state, .translated)
    }

    func testPipelineNormalizesPreferredCourseTermsBeforeTranslation() async {
        let segmentID = UUID()
        let pipeline = SubtitlePipeline(
            course: Course(
                name: "Software Architecture",
                recognitionTerms: ["MyWaikato"]
            ),
            translationEngine: TestTranslationEngine()
        )

        await pipeline.consume(
            .provisional(
                id: segmentID,
                text: "Open My Way Kato for the timetable.",
                startTime: 0,
                endTime: 1,
                provider: "test"
            )
        )
        var snapshot = await pipeline.currentSnapshot()
        XCTAssertEqual(
            snapshot.provisionalSegment?.sourceText,
            "Open MyWaikato for the timetable."
        )

        await pipeline.consume(
            .final(
                id: segmentID,
                text: "Open My Way Kato for the timetable.",
                startTime: 0,
                endTime: 2,
                speaker: nil,
                provider: "test"
            )
        )
        await pipeline.finishPendingTranslations()
        snapshot = await pipeline.currentSnapshot()

        XCTAssertEqual(
            snapshot.finalSegments.first?.sourceText,
            "Open MyWaikato for the timetable."
        )
        XCTAssertEqual(
            snapshot.finalSegments.first?.translatedText,
            "译文：Open MyWaikato for the timetable."
        )
    }

    func testPipelinePublishesFinalEnglishBeforeTranslationFinishes() async {
        let translationEngine = DeferredTranslationEngine()
        let pipeline = SubtitlePipeline(
            course: Course(name: "Concurrency"),
            translationEngine: translationEngine
        )

        await pipeline.consume(
            .final(
                id: UUID(),
                text: "English should remain responsive.",
                startTime: 0,
                endTime: 2,
                speaker: nil,
                provider: "test"
            )
        )

        var snapshot = await pipeline.currentSnapshot()
        XCTAssertEqual(snapshot.finalSegments.first?.sourceText, "English should remain responsive.")
        XCTAssertNil(snapshot.finalSegments.first?.translatedText)

        translationEngine.complete(with: "英文字幕不应被翻译阻塞。")
        await pipeline.finishPendingTranslations()
        snapshot = await pipeline.currentSnapshot()
        XCTAssertEqual(snapshot.finalSegments.first?.translatedText, "英文字幕不应被翻译阻塞。")
    }

    func testPipelineReplacesPrimaryTranslationWithRefinedTranslation() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Software Architecture"),
            translationEngine: StagedTranslationEngine(
                primary: TestTranslationEngine(),
                refinement: RefinementTranslationEngine()
            )
        )

        await pipeline.consume(
            .final(
                id: UUID(),
                text: "The event loop schedules callbacks.",
                startTime: 0,
                endTime: 2,
                speaker: nil,
                provider: "test"
            )
        )
        await pipeline.finishPendingTranslations()
        let snapshot = await pipeline.currentSnapshot()

        XCTAssertEqual(
            snapshot.finalSegments.first?.translatedText,
            "精译：The event loop schedules callbacks."
        )
    }

    func testPipelineUsesRefinementWhenPrimaryTranslationFails() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Software Architecture"),
            translationEngine: StagedTranslationEngine(
                primary: FailingTranslationEngine(),
                refinement: RefinementTranslationEngine()
            )
        )

        await pipeline.consume(
            .final(
                id: UUID(),
                text: "Transactions provide atomicity.",
                startTime: 0,
                endTime: 2,
                speaker: nil,
                provider: "test"
            )
        )
        await pipeline.finishPendingTranslations()
        let snapshot = await pipeline.currentSnapshot()

        XCTAssertEqual(
            snapshot.finalSegments.first?.translatedText,
            "精译：Transactions provide atomicity."
        )
    }

    func testPipelineReplacesRealtimeTranscriptWithChunkedOfflineTranscript() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Concurrency"),
            translationEngine: TestTranslationEngine()
        )
        await pipeline.consume(
            .final(
                id: UUID(),
                text: "Incomplete live transcript.",
                startTime: 0,
                endTime: 4,
                speaker: nil,
                provider: "live"
            )
        )

        let replaced = await pipeline.replaceFinalTranscript(
            with: "One two three four. Five six seven eight.",
            duration: 12,
            provider: "offline",
            maximumWordsPerSegment: 4
        )
        let snapshot = await pipeline.currentSnapshot()

        XCTAssertTrue(replaced)
        XCTAssertEqual(snapshot.finalSegments.count, 2)
        XCTAssertEqual(snapshot.finalSegments.map(\.provider), ["offline", "offline"])
        XCTAssertEqual(snapshot.finalSegments[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.finalSegments[0].endTime, 6, accuracy: 0.001)
        XCTAssertEqual(snapshot.finalSegments[1].endTime, 12, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.finalSegments.map(\.sourceText).joined(separator: " "),
            "One two three four. Five six seven eight."
        )
        XCTAssertTrue(snapshot.finalSegments.allSatisfy { $0.state == .translated })
    }

    func testDeterministicSummaryUsesTranslationsTermsAndActionCues() async throws {
        let document = SessionDocument(
            configuration: SessionConfiguration(
                course: Course(
                    name: "Concurrency",
                    recognitionTerms: ["Event Loop"]
                )
            ),
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 10,
                    sourceText: "Today we introduce the event loop.",
                    translatedText: "今天介绍事件循环。",
                    state: .translated,
                    provider: "test"
                ),
                TranscriptSegment(
                    startTime: 30,
                    endTime: 40,
                    sourceText: "The event loop schedules callbacks.",
                    translatedText: "事件循环负责调度回调。",
                    state: .translated,
                    provider: "test"
                ),
                TranscriptSegment(
                    startTime: 90,
                    endTime: 100,
                    sourceText: "Remember to submit the assignment before the Friday deadline.",
                    translatedText: "请在周五截止时间前提交作业。",
                    state: .translated,
                    provider: "test"
                ),
            ],
            markers: [SessionMarker(timestamp: 92, kind: .actionItem)]
        )

        let summary = try await DeterministicSummaryEngine().summarize(document)

        XCTAssertEqual(summary.overview.first, "今天介绍事件循环。")
        XCTAssertTrue(summary.keyConcepts.contains("Event Loop"))
        XCTAssertEqual(summary.actionItems, ["[01:30] 请在周五截止时间前提交作业。"])
        XCTAssertFalse(summary.isEmpty)
    }

    func testDeterministicSummaryLimitsOverviewAndHandlesEmptyTranscript() async throws {
        let segments = (0..<12).map { index in
            TranscriptSegment(
                startTime: Double(index * 10),
                endTime: Double(index * 10 + 5),
                sourceText: "Topic number \(index)",
                state: .final,
                provider: "test"
            )
        }
        let document = SessionDocument(
            configuration: SessionConfiguration(course: Course(name: "Topics")),
            segments: segments
        )
        let emptyDocument = SessionDocument(
            configuration: SessionConfiguration(course: Course(name: "Empty"))
        )

        let summary = try await DeterministicSummaryEngine().summarize(document)
        let emptySummary = try await DeterministicSummaryEngine().summarize(emptyDocument)

        XCTAssertEqual(summary.overview.count, 5)
        XCTAssertEqual(summary.overview.first, "Topic number 0")
        XCTAssertEqual(summary.overview.last, "Topic number 11")
        XCTAssertTrue(emptySummary.isEmpty)
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
            ],
            summary: SessionSummary(
                overview: ["介绍了数据库事务。"],
                keyConcepts: ["Atomicity"],
                actionItems: []
            )
        )

        try await store.save(document)
        let loaded = try await store.load(id: document.id)
        let allDocuments = try await store.list()

        XCTAssertEqual(loaded.id, document.id)
        XCTAssertEqual(loaded.configuration, document.configuration)
        XCTAssertEqual(loaded.segments, document.segments)
        XCTAssertEqual(loaded.markers, document.markers)
        XCTAssertEqual(loaded.summary, document.summary)
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

private struct RefinementTranslationEngine: TranslationEngine {
    let identifier = "refinement-test"

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        "精译：\(text)"
    }
}

private struct FailingTranslationEngine: TranslationEngine {
    let identifier = "failing-test"

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        throw TestTranslationError.unavailable
    }
}

private enum TestTranslationError: Error {
    case unavailable
}

private final class DeferredTranslationEngine: TranslationEngine, @unchecked Sendable {
    let identifier = "deferred"

    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        let pair = AsyncStream<String>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? ""
    }

    func complete(with translation: String) {
        continuation.yield(translation)
    }
}
