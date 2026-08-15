import AVFoundation
import LingoSlateAudio
import LingoSlateCore
import XCTest
@testable import LingoSlateMac

final class AppModelTests: XCTestCase {
    @MainActor
    func testTranscriptCorrectionsAreScopedByCourseLecturerAndAccent() throws {
        let suiteName = "LingoSlateCorrectionStore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranscriptCorrectionStore(defaults: defaults)
        let course = Course(
            name: "Cloud Computing",
            lecturerNames: ["Dr Singh"],
            lecturerAccent: .indianEnglish
        )
        store.record(
            heard: "telephone as the service",
            corrected: "platform as a service",
            course: course
        )

        let terms = store.approvedTerms(for: course)
        XCTAssertEqual(terms.map(\.source), ["platform as a service"])
        XCTAssertEqual(terms.first?.aliases, ["telephone as the service"])
        XCTAssertTrue(
            store.approvedTerms(
                for: Course(
                    name: "Cloud Computing",
                    lecturerNames: ["Another lecturer"],
                    lecturerAccent: .indianEnglish
                )
            ).isEmpty
        )
    }

    @MainActor
    func testCourseNameIsOptionalForStartAndWarmup() throws {
        let suiteName = "LingoSlateAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileStore = UserProfileStore(
            defaults: defaults,
            legacyBundleIdentifiers: []
        )
        let model = AppModel(profileStore: profileStore)

        model.courseName = "   "

        XCTAssertTrue(model.canStart)
        XCTAssertTrue(model.canWarmUp)
        XCTAssertEqual(model.processingMode, .local)
    }

    @MainActor
    func testRecognitionFailureSalvagesRecordingAndSessionDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateFailureSalvage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LingoSlateFailureSalvageDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let capture = FailingTestAudioCapture()
        let recognition = FailingTestRecognitionEngine()
        let model = AppModel(
            profileStore: UserProfileStore(
                defaults: defaults,
                legacyBundleIdentifiers: []
            ),
            sessionDirectoryURL: directory,
            recognitionEngineFactory: { _ in recognition },
            audioCaptureFactory: { _ in capture }
        )

        model.startSession()
        try await waitUntil { model.lifecycleState == .running }
        let samples = (0..<16_000).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / 16_000) * 0.2)
        }
        await capture.emit(
            AudioFrame(samples: samples, sampleRate: 16_000, capturedAt: 0)
        )
        try await waitUntil {
            if case .failed = model.lifecycleState { return true }
            return false
        }

        let documents = try await SessionStore(directoryURL: directory).list()
        let document = try XCTUnwrap(documents.first)
        let audioFileName = try XCTUnwrap(document.audioFileName)
        let audioURL = directory.appendingPathComponent(audioFileName)

        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(document.failureMessage, "Forced recognition failure")
        XCTAssertEqual(document.isPostProcessingComplete, false)
        XCTAssertEqual(document.audioCaptureDiagnostics?.inputDeviceUID, "test-mic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertGreaterThan(try AVAudioFile(forReading: audioURL).length, 0)
    }

    @MainActor
    func testCancelDuringPreparationFinalizesRecognitionAndReturnsToIdle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateCancelPreparation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LingoSlateCancelPreparationDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recognition = PreparingTestRecognitionEngine()
        let model = AppModel(
            profileStore: UserProfileStore(
                defaults: defaults,
                legacyBundleIdentifiers: []
            ),
            sessionDirectoryURL: directory,
            recognitionEngineFactory: { _ in recognition },
            audioCaptureFactory: { _ in FailingTestAudioCapture() }
        )

        model.startSession()
        try await waitUntil { model.lifecycleState == .preparing }
        model.stopSession()
        try await waitUntil { model.lifecycleState == .idle }

        let finalizeCount = await recognition.finalizeCount
        XCTAssertEqual(finalizeCount, 1)
        XCTAssertTrue(model.canStart)
    }

    @MainActor
    func testSonioxModeUsesCloudRecognitionFactory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateSonioxMode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LingoSlateSonioxModeDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cloudRecognition = CompletingTestRecognitionEngine()
        let capture = FailingTestAudioCapture()
        var localFactoryCalls = 0
        var cloudFactoryCalls = 0
        let model = AppModel(
            profileStore: UserProfileStore(
                defaults: defaults,
                legacyBundleIdentifiers: []
            ),
            settingsDefaults: defaults,
            sessionDirectoryURL: directory,
            recognitionEngineFactory: { _ in
                localFactoryCalls += 1
                return CompletingTestRecognitionEngine()
            },
            sonioxRecognitionFactory: { _ in
                cloudFactoryCalls += 1
                return cloudRecognition
            },
            audioCaptureFactory: { _ in capture }
        )

        model.processingMode = .soniox
        model.startSession()
        try await waitUntil { model.lifecycleState == .running }
        let samples = (0..<16_000).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / 16_000) * 0.2)
        }
        await capture.emit(
            AudioFrame(samples: samples, sampleRate: 16_000, capturedAt: 0)
        )

        XCTAssertEqual(localFactoryCalls, 0)
        XCTAssertEqual(cloudFactoryCalls, 1)
        let translationTargetLanguage = await cloudRecognition.translationTargetLanguage
        XCTAssertEqual(translationTargetLanguage, "zh")

        model.stopSession()
        try await waitUntil { model.lifecycleState == .completed }
        try await waitUntil { !model.statusMessage.hasPrefix("正在") }

        let documents = try await SessionStore(directoryURL: directory).list()
        let document = try XCTUnwrap(documents.first)
        let audioFileName = try XCTUnwrap(document.audioFileName)
        let audioURL = directory.appendingPathComponent(audioFileName)
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(model.savedAudioURL, audioURL)
        XCTAssertFalse(model.statusMessage.contains("录音保存失败"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertGreaterThan(try AVAudioFile(forReading: audioURL).length, 0)
    }

    @MainActor
    func testRepeatedStopWhileFinalizingDoesNotRestartFinalization() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateRepeatedStop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LingoSlateRepeatedStopDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recognition = DelayedCompletingTestRecognitionEngine()
        let model = AppModel(
            profileStore: UserProfileStore(
                defaults: defaults,
                legacyBundleIdentifiers: []
            ),
            sessionDirectoryURL: directory,
            recognitionEngineFactory: { _ in recognition },
            audioCaptureFactory: { _ in FailingTestAudioCapture() }
        )

        model.startSession()
        try await waitUntil { model.lifecycleState == .running }
        model.stopSession()
        try await waitUntil { model.lifecycleState == .finalizing }
        model.stopSession()
        try await waitUntil { model.lifecycleState == .completed }

        let finalizeCount = await recognition.finalizeCount
        XCTAssertEqual(finalizeCount, 1)
    }

    @MainActor
    func testShortSystemSleepKeepsSessionRunning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateShortSleep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LingoSlateShortSleepDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            profileStore: UserProfileStore(
                defaults: defaults,
                legacyBundleIdentifiers: []
            ),
            settingsDefaults: defaults,
            sessionDirectoryURL: directory,
            recognitionEngineFactory: { _ in CompletingTestRecognitionEngine() },
            audioCaptureFactory: { _ in FailingTestAudioCapture() }
        )

        model.startSession()
        try await waitUntil { model.lifecycleState == .running }
        let sleepStartedAt = Date()
        model.handleSystemWillSleep(at: sleepStartedAt)
        model.handleSystemDidWake(
            at: sleepStartedAt.addingTimeInterval(10 * 60 - 1)
        )

        XCTAssertEqual(model.lifecycleState, .running)

        model.stopSession()
        try await waitUntil { model.lifecycleState == .completed }
    }

    @MainActor
    func testTenMinuteSystemSleepAutomaticallyEndsAtGraceDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateLongSleep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LingoSlateLongSleepDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            profileStore: UserProfileStore(
                defaults: defaults,
                legacyBundleIdentifiers: []
            ),
            settingsDefaults: defaults,
            sessionDirectoryURL: directory,
            recognitionEngineFactory: { _ in CompletingTestRecognitionEngine() },
            audioCaptureFactory: { _ in FailingTestAudioCapture() }
        )

        model.startSession()
        try await waitUntil { model.lifecycleState == .running }
        let sleepStartedAt = Date()
        let expectedEnd = sleepStartedAt.addingTimeInterval(10 * 60)
        model.handleSystemWillSleep(at: sleepStartedAt)
        model.handleSystemDidWake(at: sleepStartedAt.addingTimeInterval(60 * 60))

        try await waitUntil { model.lifecycleState == .completed }
        let documents = try await SessionStore(directoryURL: directory).list()
        let document = try XCTUnwrap(documents.first)
        let actualEnd = try XCTUnwrap(document.endedAt)

        XCTAssertEqual(actualEnd.timeIntervalSince1970,
                       expectedEnd.timeIntervalSince1970,
                       accuracy: 0.01)
        XCTAssertTrue(model.statusMessage.contains("休眠超过 10 分钟"))
    }

    @MainActor
    func testWakeCaptureFailureStillUsesSleepAutoStopDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoSlateSleepFailureRace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LingoSlateSleepFailureRaceDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let capture = FailingTestAudioCapture()
        let model = AppModel(
            profileStore: UserProfileStore(
                defaults: defaults,
                legacyBundleIdentifiers: []
            ),
            settingsDefaults: defaults,
            sessionDirectoryURL: directory,
            recognitionEngineFactory: { _ in FailingTestRecognitionEngine() },
            audioCaptureFactory: { _ in capture }
        )

        model.startSession()
        try await waitUntil { model.lifecycleState == .running }
        let sessionStartedAt = try XCTUnwrap(model.startedAt)
        let sleepStartedAt = Date().addingTimeInterval(-(10 * 60 + 1))
        let expectedEnd = max(
            sleepStartedAt.addingTimeInterval(10 * 60),
            sessionStartedAt
        )
        model.handleSystemWillSleep(at: sleepStartedAt)
        await capture.emit(
            AudioFrame(samples: Array(repeating: 0.1, count: 16_000),
                       sampleRate: 16_000,
                       capturedAt: 0)
        )

        try await waitUntil {
            if case .failed = model.lifecycleState { return true }
            return false
        }
        let documents = try await SessionStore(directoryURL: directory).list()
        let document = try XCTUnwrap(documents.first)
        let actualEnd = try XCTUnwrap(document.endedAt)

        XCTAssertEqual(actualEnd.timeIntervalSince1970,
                       expectedEnd.timeIntervalSince1970,
                       accuracy: 0.01)
        XCTAssertTrue(model.statusMessage.contains("休眠超过 10 分钟"))
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}

private enum ForcedRecognitionError: LocalizedError {
    case failed

    var errorDescription: String? { "Forced recognition failure" }
}

private actor FailingTestRecognitionEngine: SpeechRecognitionEngine {
    nonisolated let events: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private var isFinished = false

    init() {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start(configuration: RecognitionConfiguration) async throws {
        continuation.yield(.started)
    }

    func accept(_ frame: AudioFrame) async throws {
        throw ForcedRecognitionError.failed
    }

    func finalize() async throws {
        guard !isFinished else { return }
        isFinished = true
        continuation.finish()
    }
}

private actor PreparingTestRecognitionEngine: SpeechRecognitionEngine {
    nonisolated let events: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private(set) var finalizeCount = 0

    init() {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start(configuration: RecognitionConfiguration) async throws {
        continuation.yield(.started)
        try await Task.sleep(for: .seconds(30))
    }

    func accept(_ frame: AudioFrame) async throws {}

    func finalize() async throws {
        finalizeCount += 1
        continuation.finish()
    }
}

private actor CompletingTestRecognitionEngine: SpeechRecognitionEngine {
    nonisolated let events: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private(set) var translationTargetLanguage: String?

    init() {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start(configuration: RecognitionConfiguration) async throws {
        translationTargetLanguage = configuration.translationTargetLanguage
        continuation.yield(.started)
    }

    func accept(_ frame: AudioFrame) async throws {}

    func finalize() async throws {
        continuation.yield(.finished)
        continuation.finish()
    }
}

private actor DelayedCompletingTestRecognitionEngine: SpeechRecognitionEngine {
    nonisolated let events: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private(set) var finalizeCount = 0

    init() {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start(configuration: RecognitionConfiguration) async throws {
        continuation.yield(.started)
    }

    func accept(_ frame: AudioFrame) async throws {}

    func finalize() async throws {
        finalizeCount += 1
        try await Task.sleep(for: .milliseconds(150))
        continuation.yield(.finished)
        continuation.finish()
    }
}

private actor FailingTestAudioCapture: RecordingAudioCaptureEngine {
    nonisolated let events: AsyncStream<AudioCaptureEvent>
    nonisolated let recordingFrames: AsyncStream<AudioFrame>
    private let eventContinuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let recordingContinuation: AsyncStream<AudioFrame>.Continuation
    private var isStopped = false

    init() {
        let eventPair = AsyncStream<AudioCaptureEvent>.makeStream()
        let recordingPair = AsyncStream<AudioFrame>.makeStream()
        events = eventPair.stream
        recordingFrames = recordingPair.stream
        eventContinuation = eventPair.continuation
        recordingContinuation = recordingPair.continuation
    }

    func requestPermission() async -> Bool { true }

    func start() async throws {
        eventContinuation.yield(.started(sampleRate: 16_000))
    }

    func emit(_ frame: AudioFrame) {
        recordingContinuation.yield(frame)
        eventContinuation.yield(.frame(frame))
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        eventContinuation.yield(.stopped)
        eventContinuation.finish()
        recordingContinuation.finish()
    }

    func captureDiagnostics() async -> AudioCaptureDiagnostics? {
        AudioCaptureDiagnostics(
            inputDeviceName: "Test Microphone",
            inputDeviceUID: "test-mic",
            inputSampleRate: 16_000
        )
    }
}
