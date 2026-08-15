import AVFoundation
import XCTest
@testable import LingoSlateAudio
@testable import LingoSlateCore

final class LingoSlateCoreTests: XCTestCase {
    func testNewZealandAcademicGlossaryUsesPhrasesWithoutAmbiguousSingleWords() {
        let terms = RegionalAcademicGlossary.approvedTerms(
            for: UserProfile(schoolName: "University of Waikato", regionCode: "NZ")
        )

        XCTAssertTrue(terms.allSatisfy(\.isApproved))
        XCTAssertTrue(terms.contains { $0.source == "paper outline" && $0.target == "课程大纲" })
        XCTAssertTrue(terms.contains { $0.source == "attend the lab" && $0.target == "参加实验课" })
        XCTAssertTrue(terms.contains { $0.source == "MyWaikato" && $0.target == "MyWaikato" })
        XCTAssertTrue(terms.contains { $0.source == "Gate 1" && $0.aliases.contains("Gate One") })
        XCTAssertTrue(terms.contains { $0.source == "IEEE" && $0.aliases.contains("I triple E") })
        XCTAssertTrue(terms.contains { $0.source == "deduction of marks" && $0.target == "扣分" })
        XCTAssertFalse(terms.contains { $0.source == "paper" || $0.source == "lab" })
        let globalTerms = RegionalAcademicGlossary.approvedTerms(
            for: UserProfile(regionCode: "US")
        )
        XCTAssertTrue(globalTerms.contains { $0.source == "Overleaf" })
        XCTAssertTrue(globalTerms.contains { $0.source == "LLM" && $0.aliases.contains("LLMs") })
        XCTAssertTrue(globalTerms.contains { $0.source == "Jetpack Compose" })
        XCTAssertFalse(globalTerms.contains { $0.source == "paper outline" })
    }

    func testMobileCourseSeedsIncludeAndroidTerminology() {
        let terms = CourseTermSeedBuilder.suggestions(
            courseName: "COMPX551 Mobile and Wearable Computing",
            schoolName: "University of Waikato"
        )

        XCTAssertTrue(terms.contains("Android Studio"))
        XCTAssertTrue(terms.contains("Jetpack Compose"))
        XCTAssertTrue(terms.contains("Kotlin"))
        XCTAssertTrue(terms.contains("XML"))
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

    func testMicrophoneRouteChangePolicyIgnoresStartupConfigurationNotification() {
        XCTAssertFalse(
            MicrophoneRouteChangePolicy.shouldFailCapture(
                expectedDeviceID: 42,
                currentDeviceID: 42
            )
        )
        XCTAssertFalse(
            MicrophoneRouteChangePolicy.shouldFailCapture(
                expectedDeviceID: 42,
                currentDeviceID: nil
            )
        )
        XCTAssertTrue(
            MicrophoneRouteChangePolicy.shouldFailCapture(
                expectedDeviceID: 42,
                currentDeviceID: 84
            )
        )
    }

    func testSessionAudioBufferTracksDurationAndReleasesFrames() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateAudioResetTests-\(UUID().uuidString)")
        let audioURL = directory.appendingPathComponent("session.m4a")
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = SessionAudioBuffer()
        try await buffer.prepareRecording(to: audioURL)
        try await buffer.append(
            AudioFrame(
                samples: [Float](repeating: 0.1, count: 3_200),
                sampleRate: 16_000,
                capturedAt: 10
            )
        )
        try await buffer.append(
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testSessionAudioBufferWritesPlayableM4A() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateAudioTests-\(UUID().uuidString)")
        let audioURL = directory.appendingPathComponent("session.m4a")
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = (0..<16_000).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / 16_000) * 0.2)
        }
        let buffer = SessionAudioBuffer()
        try await buffer.prepareRecording(to: audioURL)
        try await buffer.append(
            AudioFrame(samples: samples, sampleRate: 16_000, capturedAt: 0)
        )

        let savedURL = try await buffer.finishWriting()

        XCTAssertEqual(savedURL, audioURL)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let fileSize = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 16_000, accuracy: 0.1)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(duration, 0.9)
        XCTAssertLessThan(duration, 1.2)
        XCTAssertGreaterThan(fileSize, 500)
    }

    func testSessionAudioBufferRecoversPlayableStaleRecording() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateAudioRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let finalURL = directory.appendingPathComponent("\(sessionID.uuidString).m4a")
        let buffer = SessionAudioBuffer()
        try await buffer.prepareRecording(to: finalURL)
        try await buffer.append(
            AudioFrame(
                samples: [Float](repeating: 0.1, count: 16_000),
                sampleRate: 16_000,
                capturedAt: 0
            )
        )
        _ = try await buffer.finishWriting()
        let staleURL = directory.appendingPathComponent(
            ".\(sessionID.uuidString)-\(UUID().uuidString).m4a"
        )
        try FileManager.default.moveItem(at: finalURL, to: staleURL)

        let recovered = SessionAudioBuffer.recoverStaleRecordings(in: directory)

        XCTAssertEqual(recovered, [finalURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertGreaterThan(try AVAudioFile(forReading: finalURL).length, 0)
    }

    func testSessionAudioBufferReplaysSavedAudioInBoundedChunks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateAudioReplayTests-\(UUID().uuidString)")
        let audioURL = directory.appendingPathComponent("session.m4a")
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = SessionAudioBuffer()
        let engine = CountingRecognitionEngine()
        try await buffer.prepareRecording(to: audioURL)

        for index in 0..<60 {
            try await buffer.append(
                AudioFrame(
                    samples: [Float](repeating: 0.05, count: 1_600),
                    sampleRate: 16_000,
                    capturedAt: Double(index) / 10
                )
            )
        }
        try await buffer.replay(into: engine)

        let acceptedSampleCount = await engine.acceptedSampleCount
        let largestFrameSize = await engine.largestFrameSize
        XCTAssertGreaterThanOrEqual(acceptedSampleCount, 96_000)
        XCTAssertLessThanOrEqual(acceptedSampleCount, 98_048)
        XCTAssertLessThanOrEqual(largestFrameSize, 16_000)
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

    func testIncrementalTranscriptCursorHandlesLongExactPrefix() {
        let committed = (0..<5_000).map { "word\($0)" }.joined(separator: " ")
        let cursor = IncrementalTranscriptCursor(committedTranscript: committed)

        XCTAssertEqual(
            cursor.uncommittedText(in: committed + ", final classroom point."),
            "final classroom point."
        )
    }

    func testCourseNameIsOptionalAndNormalized() {
        XCTAssertEqual(Course(name: "   ").name, "")
        XCTAssertEqual(Course(name: "  Mobile Computing  ").name, "Mobile Computing")
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
        let suiteName = "LingoSlateTests-\(UUID().uuidString)"
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

    @MainActor
    func testUserProfileStoreMigratesLegacyBrandKey() throws {
        let suiteName = "LingoSlateMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyProfile = UserProfile(
            schoolName: "University of Waikato",
            regionCode: "NZ"
        )
        defaults.set(
            try JSONEncoder().encode(legacyProfile),
            forKey: "leccue-profile"
        )

        let store = UserProfileStore(
            defaults: defaults,
            storageKey: "lingoslate-profile",
            legacyStorageKeys: ["leccue-profile"],
            legacyBundleIdentifiers: [],
            defaultRegionCode: "US"
        )

        XCTAssertEqual(store.profile, legacyProfile)
        XCTAssertNotNil(defaults.data(forKey: "lingoslate-profile"))
    }

    @MainActor
    func testUserProfileStoreMigratesLegacyBundleDomain() throws {
        let currentSuiteName = "LingoSlateCurrentTests-\(UUID().uuidString)"
        let legacySuiteName = "LingoSlateLegacyTests-\(UUID().uuidString)"
        let currentDefaults = try XCTUnwrap(UserDefaults(suiteName: currentSuiteName))
        let legacyDefaults = try XCTUnwrap(UserDefaults(suiteName: legacySuiteName))
        defer {
            currentDefaults.removePersistentDomain(forName: currentSuiteName)
            legacyDefaults.removePersistentDomain(forName: legacySuiteName)
        }
        let legacyProfile = UserProfile(
            schoolName: "University of Waikato",
            regionCode: "NZ"
        )
        legacyDefaults.set(
            try JSONEncoder().encode(legacyProfile),
            forKey: "leccue.user-profile.v1"
        )

        let store = UserProfileStore(
            defaults: currentDefaults,
            legacyBundleIdentifiers: [legacySuiteName],
            defaultRegionCode: "US"
        )

        XCTAssertEqual(store.profile, legacyProfile)
        XCTAssertNotNil(currentDefaults.data(forKey: "lingoslate.user-profile.v1"))
    }

    func testCourseTermSeedsUseCourseAndSchoolContext() {
        let terms = CourseTermSeedBuilder.suggestions(
            courseName: "Mobile Computing and Software Architecture",
            schoolName: "University of Waikato"
        )

        XCTAssertEqual(
            Array(terms.prefix(4)),
            [
                "University of Waikato",
                "Mobile Computing and Software Architecture",
                "Mobile Computing",
                "Software Architecture",
            ]
        )
        XCTAssertTrue(terms.contains("Google Scholar"))
        XCTAssertTrue(terms.contains("in-text citation"))
        XCTAssertTrue(terms.contains { $0.caseInsensitiveCompare("software architecture") == .orderedSame })
        XCTAssertTrue(terms.contains("GitHub"))
    }

    func testCourseNameNormalizerRepairsHighConfidenceTyposAndSeedsDomainTerms() {
        let normalized = CourseNameNormalizer.normalize(
            "Secure Cloud Aplication Enginerring"
        )
        let terms = CourseTermSeedBuilder.suggestions(
            courseName: normalized,
            schoolName: "University of Waikato"
        )

        XCTAssertEqual(normalized, "Secure Cloud Application Engineering")
        XCTAssertTrue(terms.contains("Secure Cloud Application Engineering"))
        XCTAssertTrue(terms.contains("Cloud Application"))
        XCTAssertTrue(terms.contains("IaaS"))
        XCTAssertTrue(terms.contains("PaaS"))
        XCTAssertTrue(terms.contains("SaaS"))
        XCTAssertTrue(terms.contains("NIST"))
        XCTAssertTrue(terms.contains("AWS"))
        XCTAssertTrue(terms.contains("OWASP"))
        XCTAssertTrue(terms.contains("REST API"))
    }

    func testCloudCourseBuildsTranslationGlossaryWithoutAffectingOtherCourses() {
        let cloudTerms = CourseTranslationGlossary.approvedTerms(
            for: Course(name: "Secure Cloud Application Engineering")
        )
        let mobileTerms = CourseTranslationGlossary.approvedTerms(
            for: Course(name: "Mobile and Wearable Computing")
        )

        XCTAssertEqual(
            cloudTerms.first(where: { $0.source == "cloud broker" })?.target,
            "云服务经纪商"
        )
        XCTAssertTrue(cloudTerms.allSatisfy(\.isApproved))
        XCTAssertTrue(mobileTerms.isEmpty)
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

    func testTranscriptTermNormalizerRepairsMisplacedCurrencySymbols() {
        let normalizer = TranscriptTermNormalizer(preferredTerms: [])

        XCTAssertEqual(
            normalizer.normalize(
                "Fees range from 6$0 to 7$0 and the scholarship is 8$,000. Pay 60 $ today."
            ),
            "Fees range from $60 to $70 and the scholarship is $8,000. Pay $60 today."
        )
    }

    func testAudioInputQualityMonitorRequiresSustainedStrongInput() {
        var monitor = AudioInputQualityMonitor(
            observationDuration: 15,
            strongLevelThreshold: 0.32,
            minimumStrongSamples: 8
        )

        for second in 0...15 {
            _ = monitor.record(level: second == 4 ? 0.8 : 0.1, at: Double(second))
        }
        XCTAssertTrue(monitor.isInputLow)

        for second in 16...30 {
            _ = monitor.record(level: 0.5, at: Double(second))
        }
        XCTAssertFalse(monitor.isInputLow)
    }

    func testTranscriptTermNormalizerUsesApprovedAliases() {
        let normalizer = TranscriptTermNormalizer(
            course: Course(name: "Orientation"),
            approvedTerms: [
                GlossaryTerm(
                    source: "MyWaikato",
                    target: "MyWaikato",
                    aliases: ["My Way Kato"],
                    origin: .officialCourseSource,
                    isApproved: true
                ),
                GlossaryTerm(
                    source: "Gate 1",
                    target: "Gate 1",
                    aliases: ["Gate One"],
                    origin: .officialCourseSource,
                    isApproved: true
                ),
            ]
        )

        XCTAssertEqual(
            normalizer.normalize("Open My Way Kato, then park at Gate One."),
            "Open MyWaikato, then park at Gate 1."
        )
    }

    func testAcademicGlossaryRepairsSpokenAcronymAliases() {
        let normalizer = TranscriptTermNormalizer(
            course: Course(name: "Research Methods"),
            approvedTerms: RegionalAcademicGlossary.approvedTerms(
                for: UserProfile(regionCode: "NZ")
            )
        )

        XCTAssertEqual(
            normalizer.normalize("Use Over leaf and submit to I triple E."),
            "Use Overleaf and submit to IEEE."
        )
    }

    func testCourseAcronymAliasesRequireExactSafePhrases() {
        let normalizer = TranscriptTermNormalizer(
            course: Course(
                name: "Cloud Computing",
                recognitionTerms: ["IaaS", "PaaS", "SaaS", "NIST", "EC2", "S3"]
            ),
            approvedTerms: []
        )

        XCTAssertEqual(
            normalizer.normalize(
                "Infrastructure as the service, platform as a service, and software as the service."
            ),
            "IaaS, PaaS, and SaaS."
        )
        XCTAssertEqual(normalizer.normalize("The ice on the lake is thin."), "The ice on the lake is thin.")
        XCTAssertEqual(normalizer.normalize("This is important."), "This is important.")
        XCTAssertEqual(normalizer.normalize("NISC guidance."), "NISC guidance.")
        XCTAssertEqual(normalizer.normalize("Use E C two and S three."), "Use EC2 and S3.")
    }

    func testIndianEnglishAliasesRequireCourseTermsAndSentenceContext() {
        let normalizer = TranscriptTermNormalizer(
            course: Course(
                name: "Cloud Computing",
                lecturerAccent: .indianEnglish,
                recognitionTerms: ["NIST", "IaaS", "PaaS", "SaaS", "CloudTrail"]
            ),
            approvedTerms: []
        )

        XCTAssertEqual(
            normalizer.normalize(
                "The NISC security framework compares eye as cloud services, pay as platform services, and sass software services."
            ),
            "The NIST security framework compares IaaS cloud services, PaaS platform services, and SaaS software services."
        )
        XCTAssertEqual(
            normalizer.normalize("AWS cloud trail logging records API calls."),
            "AWS CloudTrail logging records API calls."
        )
        XCTAssertEqual(
            normalizer.normalize("AWS auditing examples include cloud trails and logs."),
            "AWS auditing examples include CloudTrail and logs."
        )
        XCTAssertEqual(
            normalizer.normalize(
                "The nest security standard compares IELTS infrastructure services, pass platform services, and SAS software services."
            ),
            "The NIST security standard compares IaaS infrastructure services, PaaS platform services, and SaaS software services."
        )
        XCTAssertEqual(
            normalizer.normalize("The bird built a nest near the cloud."),
            "The bird built a nest near the cloud."
        )
        XCTAssertEqual(
            normalizer.normalize("Please pass the cloud computing exam."),
            "Please pass the Cloud Computing exam."
        )
        XCTAssertEqual(normalizer.normalize("This is important."), "This is important.")
        XCTAssertEqual(
            normalizer.normalize("IS is one cloud service label in this broken transcript."),
            "IS is one cloud service label in this broken transcript."
        )
    }

    func testIndianEnglishAliasesRemainDisabledWithoutAccentProfile() {
        let normalizer = TranscriptTermNormalizer(
            course: Course(
                name: "Cloud Computing",
                recognitionTerms: ["NIST", "IaaS"]
            ),
            approvedTerms: []
        )

        XCTAssertEqual(
            normalizer.normalize("NISC security framework and eye as cloud service."),
            "NISC security framework and eye as cloud service."
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

    func testPipelineSnapshotStreamDropsStaleUIUpdates() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Concurrency"),
            translationEngine: TestTranslationEngine()
        )
        let stream = await pipeline.snapshots()
        let segmentID = UUID()

        for index in 0..<1_000 {
            await pipeline.consume(
                .provisional(
                    id: segmentID,
                    text: "Update \(index)",
                    startTime: 0,
                    endTime: Double(index),
                    provider: "test"
                )
            )
        }

        var iterator = stream.makeAsyncIterator()
        let latest = await iterator.next()
        XCTAssertEqual(latest?.provisionalSegment?.sourceText, "Update 999")
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

    func testPipelineKeepsChineseDiscussionButExcludesItFromTranslationContext() async {
        let engine = RecordingTranslationEngine(prefix: "译文")
        let pipeline = SubtitlePipeline(
            course: Course(name: "Software Architecture"),
            translationEngine: engine
        )

        await pipeline.consume(
            .final(
                id: UUID(),
                text: "这个作业什么时候交？",
                startTime: 0,
                endTime: 2,
                speaker: nil,
                provider: "test"
            )
        )
        await pipeline.consume(
            .final(
                id: UUID(),
                text: "The assignment is due on Friday.",
                startTime: 2,
                endTime: 4,
                speaker: nil,
                provider: "test"
            )
        )
        _ = await pipeline.finishPendingTranslations(timeout: .seconds(1))

        let snapshot = await pipeline.currentSnapshot()
        let contexts = await engine.contexts
        XCTAssertEqual(snapshot.finalSegments.count, 2)
        XCTAssertNil(snapshot.finalSegments[0].translatedText)
        XCTAssertNotNil(snapshot.finalSegments[0].translationExclusionReason)
        XCTAssertEqual(snapshot.finalSegments[0].state, .final)
        XCTAssertEqual(snapshot.finalSegments[1].translatedText, "译文：The assignment is due on Friday.")
        XCTAssertEqual(snapshot.finalSegments[1].translationProvider, engine.identifier)
        XCTAssertTrue(contexts.allSatisfy { context in
            !context.recentSourceText.contains("这个作业什么时候交？")
        })
    }

    func testPipelineUsesSonioxTranslationWithoutCallingLocalEngine() async {
        let engine = RecordingTranslationEngine(prefix: "本地")
        let pipeline = SubtitlePipeline(
            course: Course(name: "Cloud Computing"),
            translationEngine: engine
        )
        let result = BilingualRecognitionResult(
            id: UUID(),
            sourceText: "The assignment is due on Friday.",
            translatedText: "作业周五截止。",
            sourceLanguage: "en",
            startTime: 0,
            endTime: 3,
            speaker: "1",
            recognitionProvider: "soniox-stt-rt-v5",
            translationProvider: "soniox-translation-stt-rt-v5"
        )

        await pipeline.consume(.bilingualProvisional(result))
        var snapshot = await pipeline.currentSnapshot()
        XCTAssertEqual(snapshot.provisionalSegment?.translatedText, "作业周五截止。")

        await pipeline.consume(.bilingualFinal(result))
        _ = await pipeline.finishPendingTranslations(timeout: .milliseconds(100))
        snapshot = await pipeline.currentSnapshot()
        let contexts = await engine.contexts

        XCTAssertEqual(snapshot.finalSegments.first?.sourceText, result.sourceText)
        XCTAssertEqual(snapshot.finalSegments.first?.translatedText, result.translatedText)
        XCTAssertEqual(
            snapshot.finalSegments.first?.translationProvider,
            result.translationProvider
        )
        XCTAssertEqual(snapshot.finalSegments.first?.sourceLanguage, "en")
        XCTAssertTrue(contexts.isEmpty)
    }

    func testPipelineExcludesSonioxChineseSourceEvenWithoutHanCharacters() async {
        let engine = RecordingTranslationEngine(prefix: "本地")
        let pipeline = SubtitlePipeline(
            course: Course(name: "Cloud Computing"),
            translationEngine: engine
        )

        await pipeline.consume(
            .bilingualFinal(
                BilingualRecognitionResult(
                    id: UUID(),
                    sourceText: "OK?",
                    translatedText: "好吗？",
                    sourceLanguage: "zh",
                    startTime: 0,
                    endTime: 1,
                    recognitionProvider: "soniox-stt-rt-v5",
                    translationProvider: "soniox-translation-stt-rt-v5"
                )
            )
        )

        let snapshot = await pipeline.currentSnapshot()
        let contexts = await engine.contexts
        XCTAssertEqual(snapshot.finalSegments.first?.sourceText, "OK?")
        XCTAssertNil(snapshot.finalSegments.first?.translatedText)
        XCTAssertNotNil(snapshot.finalSegments.first?.translationExclusionReason)
        XCTAssertEqual(snapshot.finalSegments.first?.sourceLanguage, "zh")
        XCTAssertTrue(contexts.isEmpty)
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
        XCTAssertEqual(
            snapshot.finalSegments.first?.translationProvider,
            "refinement-test"
        )
    }

    func testPipelineContextuallyRetranslatesTheLatestThreeLiveSegments() async {
        let primary = RecordingTranslationEngine(prefix: "快译")
        let refinement = RecordingTranslationEngine(prefix: "精译")
        let pipeline = SubtitlePipeline(
            course: Course(name: "Cloud Computing"),
            translationEngine: StagedTranslationEngine(
                primary: primary,
                refinement: refinement,
                refinementPolicy: .contextualAndPostClass
            )
        )

        for index in 0..<3 {
            await pipeline.consume(
                .final(
                    id: UUID(),
                    text: "Sentence \(index + 1).",
                    startTime: Double(index),
                    endTime: Double(index + 1),
                    speaker: nil,
                    provider: "test"
                )
            )
        }
        _ = await pipeline.finishPendingTranslations(timeout: .seconds(1))

        let primaryContexts = await primary.contexts
        let refinementContexts = await refinement.contexts
        let snapshot = await pipeline.currentSnapshot()
        XCTAssertGreaterThanOrEqual(primaryContexts.count, 3)
        XCTAssertLessThanOrEqual(primaryContexts.count, 5)
        XCTAssertEqual(refinementContexts.count, 3)
        XCTAssertTrue(refinementContexts.allSatisfy { $0.phase == .contextualLive })
        XCTAssertEqual(
            Set(refinementContexts.map(\.recentSourceText)),
            Set([
                ["Sentence 2.", "Sentence 3."],
                ["Sentence 1.", "Sentence 3."],
                ["Sentence 1.", "Sentence 2."],
            ])
        )
        XCTAssertEqual(snapshot.finalSegments.first?.translatedText, "精译：Sentence 1.")
        XCTAssertEqual(snapshot.finalSegments.last?.translatedText, "精译：Sentence 3.")
    }

    func testContextualRetranslationWaitsForPendingQuickTranslations() async {
        let primary = DeferredTranslationEngine()
        let refinement = RecordingTranslationEngine(prefix: "精译")
        let pipeline = SubtitlePipeline(
            course: Course(name: "Cloud Computing"),
            translationEngine: StagedTranslationEngine(
                primary: primary,
                refinement: refinement,
                refinementPolicy: .contextualAndPostClass
            ),
            maximumPendingTranslations: 1
        )

        for index in 0..<3 {
            await pipeline.consume(
                .final(
                    id: UUID(),
                    text: "Sentence \(index + 1).",
                    startTime: Double(index),
                    endTime: Double(index + 1),
                    speaker: nil,
                    provider: "test"
                )
            )
        }
        for index in 0..<5 {
            primary.complete(with: "快译 \(index)")
            try? await Task.sleep(for: .milliseconds(20))
        }

        let completed = await pipeline.finishPendingTranslations(timeout: .seconds(1))
        let snapshot = await pipeline.currentSnapshot()
        let refinementContexts = await refinement.contexts

        XCTAssertTrue(completed)
        XCTAssertEqual(refinementContexts.count, 3)
        XCTAssertEqual(
            snapshot.finalSegments.compactMap(\.translatedText),
            ["精译：Sentence 1.", "精译：Sentence 2.", "精译：Sentence 3."]
        )
    }

    func testCorrectedEnglishIsRetranslatedAndLearnedForSession() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Cloud Computing"),
            translationEngine: StagedTranslationEngine(
                primary: TestTranslationEngine(),
                refinement: RefinementTranslationEngine(),
                refinementPolicy: .contextualAndPostClass
            )
        )
        let firstID = UUID()
        await pipeline.consume(
            .final(
                id: firstID,
                text: "Use eye as cloud service.",
                startTime: 0,
                endTime: 1,
                speaker: nil,
                provider: "test"
            )
        )
        _ = await pipeline.finishPendingTranslations(timeout: .seconds(1))

        await pipeline.correctSegment(id: firstID, sourceText: "Use IaaS cloud service.")
        _ = await pipeline.finishPendingTranslations(timeout: .seconds(1))
        await pipeline.consume(
            .final(
                id: UUID(),
                text: "Use eye as cloud service.",
                startTime: 1,
                endTime: 2,
                speaker: nil,
                provider: "test"
            )
        )
        _ = await pipeline.finishPendingTranslations(timeout: .seconds(1))

        let snapshot = await pipeline.currentSnapshot()
        XCTAssertEqual(snapshot.finalSegments[0].sourceText, "Use IaaS cloud service.")
        XCTAssertEqual(snapshot.finalSegments[0].translatedText, "精译：Use IaaS cloud service.")
        XCTAssertTrue(snapshot.finalSegments[0].isUserCorrected)
        XCTAssertEqual(snapshot.finalSegments[1].sourceText, "Use IaaS cloud service.")
    }

    func testPipelineKeepsPrimaryTranslationWhenRefinementFailsQualityCheck() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Software Architecture"),
            translationEngine: StagedTranslationEngine(
                primary: TestTranslationEngine(),
                refinement: FailingTranslationEngine()
            )
        )

        await pipeline.consume(
            .final(
                id: UUID(),
                text: "Each paper is worth 15 credits.",
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
            "译文：Each paper is worth 15 credits."
        )
        XCTAssertEqual(snapshot.finalSegments.first?.translationProvider, "test")
        XCTAssertNotNil(snapshot.finalSegments.first?.translationFailureReason)
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

    func testPipelinePreservesOfflineRecognitionBoundaries() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Timing"),
            translationEngine: TestTranslationEngine()
        )

        let replaced = await pipeline.replaceFinalTranscript(
            with: [
                TimedTranscriptChunk(text: "First concept.", startTime: 1.5, endTime: 4),
                TimedTranscriptChunk(text: "Second concept.", startTime: 9, endTime: 12.5),
            ],
            provider: "offline"
        )
        let snapshot = await pipeline.currentSnapshot()

        XCTAssertTrue(replaced)
        XCTAssertEqual(snapshot.finalSegments.map(\.startTime), [1.5, 9])
        XCTAssertEqual(snapshot.finalSegments.map(\.endTime), [4, 12.5])
    }

    func testPipelineSplitsLongOfflineSentenceAtClauseBoundaries() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Writing"),
            translationEngine: TestTranslationEngine()
        )

        let replaced = await pipeline.replaceFinalTranscript(
            with: "One two three four five six, seven eight nine ten eleven twelve; "
                + "thirteen fourteen fifteen sixteen seventeen eighteen.",
            duration: 18,
            provider: "offline",
            maximumWordsPerSegment: 8
        )
        let snapshot = await pipeline.currentSnapshot()

        XCTAssertTrue(replaced)
        XCTAssertEqual(snapshot.finalSegments.count, 3)
        XCTAssertTrue(snapshot.finalSegments[0].sourceText.hasSuffix(","))
        XCTAssertTrue(snapshot.finalSegments[1].sourceText.hasSuffix(";"))
        XCTAssertTrue(
            snapshot.finalSegments.allSatisfy {
                $0.sourceText.split(whereSeparator: \.isWhitespace).count <= 8
            }
        )
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
        var segments: [TranscriptSegment] = []
        for index in 0..<12 {
            let startTime = TimeInterval(index * 10)
            let sourceText = "Topic number " + String(index)
            segments.append(
                TranscriptSegment(
                    startTime: startTime,
                    endTime: startTime + 5,
                    sourceText: sourceText,
                    state: .final,
                    provider: "test"
                )
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

    func testDeterministicSummaryDoesNotTreatExampleAsActionItem() async throws {
        let document = SessionDocument(
            configuration: SessionConfiguration(course: Course(name: "Cloud Computing")),
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 4,
                    sourceText: "For example, S3 provides object storage.",
                    state: .final,
                    provider: "test"
                ),
            ]
        )

        let summary = try await DeterministicSummaryEngine().summarize(document)

        XCTAssertTrue(summary.actionItems.isEmpty)
    }

    func testDeterministicSummaryExcludesChineseDiscussion() async throws {
        let document = SessionDocument(
            configuration: SessionConfiguration(course: Course(name: "Cloud Computing")),
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 2,
                    sourceText: "这个作业很难。",
                    state: .final,
                    provider: "test",
                    translationExclusionReason: "detectedChineseDiscussion"
                ),
                TranscriptSegment(
                    startTime: 2,
                    endTime: 4,
                    sourceText: "The assignment is due on Friday.",
                    translatedText: "作业周五截止。",
                    state: .translated,
                    provider: "test"
                ),
            ]
        )

        let summary = try await DeterministicSummaryEngine().summarize(document)

        XCTAssertFalse(summary.overview.contains(where: { $0.contains("很难") }))
        XCTAssertTrue(summary.overview.contains("作业周五截止。"))
    }

    func testPipelineTranslationDeadlineCancelsHungWork() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Concurrency"),
            translationEngine: DeferredTranslationEngine()
        )
        await pipeline.consume(
            .final(
                id: UUID(),
                text: "This translation never completes.",
                startTime: 0,
                endTime: 2,
                speaker: nil,
                provider: "test"
            )
        )

        let clock = ContinuousClock()
        let started = clock.now
        let completed = await pipeline.finishPendingTranslations(timeout: .milliseconds(100))

        XCTAssertFalse(completed)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testPipelineDrainsDeferredTranslationsWithinBound() async {
        let engine = DeferredTranslationEngine()
        let pipeline = SubtitlePipeline(
            course: Course(name: "Concurrency"),
            translationEngine: engine,
            maximumPendingTranslations: 1
        )
        for index in 0..<3 {
            await pipeline.consume(
                .final(
                    id: UUID(),
                    text: "Segment \(index)",
                    startTime: Double(index),
                    endTime: Double(index + 1),
                    speaker: nil,
                    provider: "test"
                )
            )
        }

        for index in 0..<3 {
            engine.complete(with: "译文 \(index)")
            try? await Task.sleep(for: .milliseconds(20))
        }
        let completed = await pipeline.finishPendingTranslations(timeout: .seconds(1))
        let snapshot = await pipeline.currentSnapshot()

        XCTAssertTrue(completed)
        XCTAssertEqual(snapshot.finalSegments.compactMap(\.translatedText).count, 3)
    }

    func testPipelineRetranslatesPreviouslyFailedSegments() async {
        let pipeline = SubtitlePipeline(
            course: Course(name: "Resilience"),
            translationEngine: FlakyTranslationEngine()
        )
        await pipeline.consume(
            .final(
                id: UUID(),
                text: "Retry this segment.",
                startTime: 0,
                endTime: 2,
                speaker: nil,
                provider: "test"
            )
        )
        _ = await pipeline.finishPendingTranslations(timeout: .seconds(1))
        await pipeline.retranslateMissing()
        _ = await pipeline.finishPendingTranslations(timeout: .seconds(1))

        let snapshot = await pipeline.currentSnapshot()
        XCTAssertEqual(snapshot.finalSegments.first?.translatedText, "重试成功")
    }

    func testSessionStoreRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directoryURL: directory)
        let document = SessionDocument(
            configuration: SessionConfiguration(
                course: Course(name: "Advanced Databases"),
                audioRetention: .keep
            ),
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 2,
                    sourceText: "Transactions provide atomicity.",
                    translatedText: "事务提供原子性。",
                    state: .translated,
                    provider: "test",
                    translationProvider: "translategemma-4b",
                    sourceLanguage: "en"
                )
            ],
            summary: SessionSummary(
                overview: ["介绍了数据库事务。"],
                keyConcepts: ["Atomicity"],
                actionItems: []
            ),
            audioFileName: "session.m4a",
            preparationDiagnostics: SessionPreparationDiagnostics(
                asrModelReady: true,
                quickTranslationReady: true,
                enhancedTranslationReady: true,
                usedFoundationModel: false,
                generatedTermCount: 0,
                terms: ["Transactions"],
                prewarmedRecognitionReused: true
            ),
            audioCaptureDiagnostics: AudioCaptureDiagnostics(
                inputDeviceName: "MacBook Microphone",
                inputDeviceUID: "test-device",
                inputSampleRate: 48_000,
                recognitionDroppedFrameCount: 2,
                recordingDroppedFrameCount: 0,
                routeChangeCount: 1
            )
        )

        try await store.save(document)
        let loaded = try await store.load(id: document.id)
        let allDocuments = try await store.list()

        XCTAssertEqual(loaded.id, document.id)
        XCTAssertEqual(loaded.configuration, document.configuration)
        XCTAssertEqual(loaded.segments, document.segments)
        XCTAssertEqual(loaded.segments.first?.sourceText, "Transactions provide atomicity.")
        XCTAssertEqual(loaded.segments.first?.translatedText, "事务提供原子性。")
        XCTAssertEqual(loaded.segments.first?.translationProvider, "translategemma-4b")
        XCTAssertEqual(loaded.segments.first?.sourceLanguage, "en")
        XCTAssertEqual(loaded.configuration.audioRetention, .keep)
        XCTAssertEqual(loaded.audioFileName, "session.m4a")
        XCTAssertEqual(loaded.markers, document.markers)
        XCTAssertEqual(loaded.summary, document.summary)
        XCTAssertEqual(loaded.audioCaptureDiagnostics, document.audioCaptureDiagnostics)
        let loadedPreparation = try XCTUnwrap(loaded.preparationDiagnostics)
        let expectedPreparation = try XCTUnwrap(document.preparationDiagnostics)
        XCTAssertEqual(loadedPreparation.asrModelReady, expectedPreparation.asrModelReady)
        XCTAssertEqual(loadedPreparation.quickTranslationReady, expectedPreparation.quickTranslationReady)
        XCTAssertEqual(loadedPreparation.enhancedTranslationReady, expectedPreparation.enhancedTranslationReady)
        XCTAssertEqual(loadedPreparation.usedFoundationModel, expectedPreparation.usedFoundationModel)
        XCTAssertEqual(loadedPreparation.generatedTermCount, expectedPreparation.generatedTermCount)
        XCTAssertEqual(loadedPreparation.terms, expectedPreparation.terms)
        XCTAssertEqual(
            loadedPreparation.prewarmedRecognitionReused,
            expectedPreparation.prewarmedRecognitionReused
        )
        XCTAssertEqual(
            loadedPreparation.preparedAt.timeIntervalSince1970,
            expectedPreparation.preparedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            loaded.startedAt.timeIntervalSince1970,
            document.startedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(allDocuments.map(\.id), [document.id])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["\(document.id.uuidString).json"]
        )
    }

    func testSessionStoreDeleteRemovesDocumentAndOwnedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateSessionDelete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = SessionStore(directoryURL: directory)
        let document = SessionDocument(
            configuration: SessionConfiguration(course: Course(name: "Cloud Computing")),
            audioFileName: "lecture.m4a"
        )
        let audioURL = directory.appendingPathComponent("lecture.m4a")
        let unrelatedURL = directory.appendingPathComponent("keep.txt")
        try Data([1, 2, 3]).write(to: audioURL)
        try Data([4, 5, 6]).write(to: unrelatedURL)
        try await store.save(document)

        try await store.delete(id: document.id)

        let remaining = try await store.list()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testSessionStoreSkipsCorruptFilesAndDecodesLegacyDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateStoreCompatibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directoryURL: directory)
        let document = SessionDocument(
            configuration: SessionConfiguration(course: Course(name: "Legacy"))
        )
        try await store.save(document)

        let documentURL = directory.appendingPathComponent("\(document.id.uuidString).json")
        let data = try Data(contentsOf: documentURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schemaVersion"] = nil
        object["processedAt"] = nil
        object["failureMessage"] = nil
        object["isPostProcessingComplete"] = nil
        object["audioCaptureDiagnostics"] = nil
        try JSONSerialization.data(withJSONObject: object)
            .write(to: documentURL, options: .atomic)
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("corrupt.json")
        )

        let loaded = try await store.load(id: document.id)
        let listed = try await store.list()

        XCTAssertNil(loaded.schemaVersion)
        XCTAssertNil(loaded.processedAt)
        XCTAssertNil(loaded.failureMessage)
        XCTAssertNil(loaded.isPostProcessingComplete)
        XCTAssertNil(loaded.audioCaptureDiagnostics)
        XCTAssertEqual(listed.map(\.id), [document.id])
    }
}

private struct TestTranslationEngine: TranslationEngine {
    let identifier = "test"

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        "译文：\(text)"
    }
}

private actor RecordingTranslationEngine: TranslationEngine {
    nonisolated let identifier = "recording-translation"
    private let prefix: String
    private(set) var contexts: [TranslationContext] = []

    init(prefix: String) {
        self.prefix = prefix
    }

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        contexts.append(context)
        return "\(prefix)：\(text)"
    }
}

private actor CountingRecognitionEngine: SpeechRecognitionEngine {
    nonisolated let events: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private(set) var acceptedSampleCount = 0
    private(set) var largestFrameSize = 0

    init() {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start(configuration: RecognitionConfiguration) async throws {
        continuation.yield(.started)
    }

    func accept(_ frame: AudioFrame) async throws {
        acceptedSampleCount += frame.samples.count
        largestFrameSize = max(largestFrameSize, frame.samples.count)
    }

    func finalize() async throws {
        continuation.yield(.finished)
        continuation.finish()
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

private actor FlakyTranslationEngine: TranslationEngine {
    nonisolated let identifier = "flaky"
    private var attempts = 0

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        attempts += 1
        if attempts == 1 {
            throw TestTranslationError.unavailable
        }
        return "重试成功"
    }
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
