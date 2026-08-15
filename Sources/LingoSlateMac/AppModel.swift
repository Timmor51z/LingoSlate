import LingoSlateAudio
import LingoSlateCore
import LingoSlateSoniox
import LingoSlateTranslation
import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var courseName = ""
    @Published var lecturerName = ""
    @Published var lecturerAccent: LecturerAccentProfile? = nil
    @Published var courseTermsText = ""
    @Published var sessionKind: SessionKind = .lecture
    @Published var processingMode: ProcessingMode = .local {
        didSet {
            guard oldValue != processingMode else { return }
            if processingMode == .soniox, !sonioxCredentialStore.hasAPIKey {
                statusMessage = "请先在设置中配置 Soniox API Key"
            }
            Task { [weak self] in
                guard let self else { return }
                if self.processingMode != .highAccuracy {
                    await self.releaseEnhancedTranslationModel()
                }
                await self.discardPrewarmedEngine()
            }
        }
    }
    @Published var audioSource: AudioSource = .microphone
    @Published private(set) var lifecycleState: SessionLifecycleState = .idle
    @Published private(set) var snapshot = TranscriptSnapshot()
    @Published private(set) var markers: [SessionMarker] = []
    @Published private(set) var statusMessage = "就绪"
    @Published private(set) var startedAt: Date?
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var captureSampleRate: Double?
    @Published private(set) var isWarmingUp = false
    @Published private(set) var summary: SessionSummary?
    @Published private(set) var isSummarizing = false
    @Published private(set) var isEnhancedTranslationReady = false
    @Published private(set) var savedAudioURL: URL?
    @Published private(set) var warmupDiagnostics: SessionPreparationDiagnostics?
    @Published private(set) var isInputLevelLow = false
    @Published private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    @Published var selectedInputDeviceUID: String? {
        didSet {
            settingsDefaults.set(
                selectedInputDeviceUID,
                forKey: Self.selectedInputDeviceKey
            )
        }
    }
    @Published private(set) var isTestingMicrophone = false

    private let stateMachine = SessionStateMachine()
    private let sessionDirectoryURL: URL
    private let sessionStore: SessionStore
    private let postClassAudioBuffer: SessionAudioBuffer
    private let profileStore: UserProfileStore
    private let sonioxCredentialStore: SonioxCredentialStore
    private let settingsDefaults: UserDefaults
    private let recognitionEngineFactory: (LocalRecognitionProfile) -> any SpeechRecognitionEngine
    private let sonioxRecognitionFactory: (String) -> any SpeechRecognitionEngine
    private let audioCaptureFactory: (String?) -> any AudioCaptureEngine
    private let coursePreparationService = CoursePreparationService()
    private let correctionStore: TranscriptCorrectionStore
    private let summaryEngine = LocalSummaryEngine()
    let translationEngine = AppleTranslationEngine()
    private let refinementTranslationEngine = TranslateGemmaTranslationEngine()

    private var pipeline: SubtitlePipeline?
    private var recognitionEngine: (any SpeechRecognitionEngine)?
    private var audioCapture: (any AudioCaptureEngine)?
    private var currentDocument: SessionDocument?
    private var startupTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var postClassTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    private var coursePreparationTask: Task<CoursePreparationResult, Never>?
    private var translationPreparationTask: Task<Bool, Never>?
    private var refinementPreparationTask: Task<Bool, Never>?
    private var enhancedModelReleaseTask: Task<Void, Never>?
    private var prewarmedEngine: (any SpeechRecognitionEngine)?
    private var prewarmedSignature: RecognitionWarmupSignature?
    private var warmupDiagnosticsSignature: RecognitionWarmupSignature?
    private var inputQualityMonitor = AudioInputQualityMonitor()
    private var lastCheckpointedFinalCount = 0
    private var lastCheckpointedTranslationCount = 0
    private var lastCheckpointedRefinedCount = 0
    private var isCompletingSession = false
    private var isHandlingFailure = false
    private var isStoppingSession = false
    private var pendingCompletionNotice: String?
    private var microphoneTestTask: Task<Void, Never>?
    private var microphoneTestURL: URL?

    private static let selectedInputDeviceKey = "lingoslate.selected-input-device.v1"
    private static let sleepSessionIDKey = "lingoslate.active-session-sleep-id.v1"
    private static let sleepStartedAtKey = "lingoslate.active-session-sleep-started-at.v1"
    private static let sleepAutoStopInterval: TimeInterval = 10 * 60

    var storedSessionDirectoryURL: URL { sessionDirectoryURL }

    init(
        profileStore: UserProfileStore = UserProfileStore(),
        sonioxCredentialStore: SonioxCredentialStore? = nil,
        settingsDefaults: UserDefaults = .standard,
        sessionDirectoryURL: URL? = nil,
        postClassAudioBuffer: SessionAudioBuffer = SessionAudioBuffer(),
        recognitionEngineFactory: @escaping (LocalRecognitionProfile) -> any SpeechRecognitionEngine = {
            LocalRecognitionEngineFactory.make(profile: $0)
        },
        sonioxRecognitionFactory: @escaping (String) -> any SpeechRecognitionEngine = {
            SonioxRecognitionEngine(apiKey: $0)
        },
        audioCaptureFactory: @escaping (String?) -> any AudioCaptureEngine = {
            MicrophoneAudioCapture(deviceUID: $0)
        }
    ) {
        let sessionDirectoryURL = sessionDirectoryURL ?? Self.sessionDirectory()
        self.profileStore = profileStore
        self.sonioxCredentialStore = sonioxCredentialStore ?? SonioxCredentialStore()
        self.settingsDefaults = settingsDefaults
        correctionStore = TranscriptCorrectionStore(defaults: settingsDefaults)
        self.sessionDirectoryURL = sessionDirectoryURL
        self.postClassAudioBuffer = postClassAudioBuffer
        self.recognitionEngineFactory = recognitionEngineFactory
        self.sonioxRecognitionFactory = sonioxRecognitionFactory
        self.audioCaptureFactory = audioCaptureFactory
        let devices = MicrophoneDeviceCatalog.availableInputDevices()
        availableInputDevices = devices
        let storedDeviceUID = settingsDefaults.string(forKey: Self.selectedInputDeviceKey)
        selectedInputDeviceUID = devices.contains { $0.uid == storedDeviceUID }
            ? storedDeviceUID
            : MicrophoneDeviceCatalog.defaultInputDeviceUID() ?? devices.first?.uid
        sessionStore = SessionStore(directoryURL: sessionDirectoryURL)
        Task { [weak self] in
            await self?.recoverInterruptedSessions()
        }
    }

    private static func sessionDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let currentDirectory = applicationSupport
            .appendingPathComponent("LingoSlate", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        let legacyDirectory = applicationSupport
            .appendingPathComponent("ClassBridge", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)

        guard !fileManager.fileExists(atPath: currentDirectory.path),
              fileManager.fileExists(atPath: legacyDirectory.path) else {
            return currentDirectory
        }

        do {
            try fileManager.createDirectory(
                at: currentDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
            return currentDirectory
        } catch {
            return legacyDirectory
        }
    }

    private func recoverInterruptedSessions() async {
        let sleepCheckpoint = storedSleepCheckpoint()
        let recoveredURLs = SessionAudioBuffer.recoverStaleRecordings(
            in: sessionDirectoryURL
        )
        var recoveredSessionIDs = Set<UUID>()
        var recoveredAfterLongSleep = false

        for audioURL in recoveredURLs {
            guard let sessionID = UUID(
                uuidString: audioURL.deletingPathExtension().lastPathComponent
            ), var document = try? await sessionStore.load(id: sessionID) else { continue }
            recoveredSessionIDs.insert(sessionID)
            document.audioFileName = audioURL.lastPathComponent
            if let sleepCheckpoint,
               sleepCheckpoint.sessionID == sessionID,
               Date().timeIntervalSince(sleepCheckpoint.startedAt)
                    >= Self.sleepAutoStopInterval {
                document.endedAt = autoStopDate(
                    sleepStartedAt: sleepCheckpoint.startedAt,
                    sessionStartedAt: document.startedAt
                )
                document.failureMessage = "笔记本休眠超过 10 分钟，课堂已自动结束并恢复录音"
                recoveredAfterLongSleep = true
            } else if document.endedAt == nil {
                document.endedAt = try? audioURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                document.failureMessage = "上次课堂意外中断，已恢复录音和已保存字幕"
            }
            document.isPostProcessingComplete = false
            try? await sessionStore.save(document)
        }

        if let sleepCheckpoint,
           !recoveredSessionIDs.contains(sleepCheckpoint.sessionID),
           Date().timeIntervalSince(sleepCheckpoint.startedAt)
                >= Self.sleepAutoStopInterval,
           var document = try? await sessionStore.load(id: sleepCheckpoint.sessionID) {
            document.endedAt = autoStopDate(
                sleepStartedAt: sleepCheckpoint.startedAt,
                sessionStartedAt: document.startedAt
            )
            document.failureMessage = "笔记本休眠超过 10 分钟，课堂已自动结束"
            document.isPostProcessingComplete = false
            try? await sessionStore.save(document)
            recoveredSessionIDs.insert(sleepCheckpoint.sessionID)
            recoveredAfterLongSleep = true
        }
        clearSleepCheckpoint()

        guard !recoveredSessionIDs.isEmpty,
              lifecycleState == .idle,
              currentDocument == nil else { return }
        statusMessage = recoveredAfterLongSleep
            ? "笔记本休眠超过 10 分钟，上次课堂已自动结束"
            : "已恢复上次意外中断的课堂录音"
    }

    var canStart: Bool {
        lifecycleState == .idle
            && audioSource == .microphone
            && !isWarmingUp
            && !isTestingMicrophone
    }

    var canWarmUp: Bool {
        lifecycleState == .idle
            && !isWarmingUp
            && !isTestingMicrophone
    }

    var isCourseWarm: Bool {
        if processingMode == .soniox {
            return warmupDiagnostics != nil
                && warmupDiagnosticsSignature == currentWarmupSignature
        }
        return prewarmedEngine != nil && prewarmedSignature == currentWarmupSignature
    }

    var isActive: Bool {
        switch lifecycleState {
        case .preparing, .running, .paused, .finalizing:
            return true
        default:
            return false
        }
    }

    var canAddMarker: Bool {
        lifecycleState == .running
    }

    var canSkipPostClassOptimization: Bool {
        lifecycleState == .finalizing && postClassTask != nil
    }

    func startSession() {
        guard canStart else { return }
        clearSleepCheckpoint()
        pendingCompletionNotice = nil
        startupTask?.cancel()
        eventTask?.cancel()
        captureTask?.cancel()
        recordingTask?.cancel()
        snapshotTask?.cancel()
        finalizationTask?.cancel()
        checkpointTask?.cancel()
        postClassTask?.cancel()
        postClassTask = nil
        enhancedModelReleaseTask?.cancel()
        enhancedModelReleaseTask = nil

        let course = Course(
            name: courseName,
            lecturerNames: lecturerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [lecturerName],
            lecturerAccent: lecturerAccent,
            recognitionTerms: parsedCourseTerms
        )
        let configuration = SessionConfiguration(
            course: course,
            kind: sessionKind,
            processingMode: processingMode,
            audioSource: audioSource,
            audioRetention: .keep
        )
        let sessionTranslationEngine: any TranslationEngine = processingMode == .highAccuracy
            ? StagedTranslationEngine(
                primary: translationEngine,
                refinement: refinementTranslationEngine,
                refinementPolicy: .contextualAndPostClass
            )
            : translationEngine
        let approvedTerms = RegionalAcademicGlossary.approvedTerms(
            for: profileStore.profile
        ) + CourseTranslationGlossary.approvedTerms(for: course)
        let pipeline = SubtitlePipeline(
            course: course,
            translationEngine: sessionTranslationEngine,
            approvedTerms: approvedTerms,
            recognitionCorrections: correctionStore.approvedTerms(for: course)
        )
        if processingMode != .soniox {
            translationEngine.activate(retryIfFailed: true)
        }
        let recognitionProfile: LocalRecognitionProfile = processingMode == .highAccuracy
            ? .highAccuracy
            : .energySaver
        let warmupSignature = currentWarmupSignature
        let hasMatchingPrewarmedEngine = prewarmedEngine != nil
            && prewarmedSignature == warmupSignature
        var sessionPreparationDiagnostics = hasMatchingPrewarmedEngine
            && warmupDiagnosticsSignature == warmupSignature
            ? warmupDiagnostics
            : nil
        let prewarmedEngine = processingMode == .soniox
            ? nil
            : takePrewarmedEngine(for: warmupSignature)
        let engine: any SpeechRecognitionEngine = processingMode == .soniox
            ? sonioxRecognitionFactory(sonioxCredentialStore.effectiveAPIKey)
            : prewarmedEngine ?? recognitionEngineFactory(recognitionProfile)
        let usesPrewarmedEngine = prewarmedEngine != nil
        sessionPreparationDiagnostics?.prewarmedRecognitionReused = usesPrewarmedEngine
        if sessionPreparationDiagnostics != nil {
            warmupDiagnostics = sessionPreparationDiagnostics
        }
        let capture = audioCaptureFactory(selectedInputDeviceUID)
        let shouldRunPostClassOptimization = processingMode == .highAccuracy
        let audioBuffer = postClassAudioBuffer

        self.pipeline = pipeline
        recognitionEngine = engine
        audioCapture = capture
        let document = SessionDocument(
            configuration: configuration,
            preparationDiagnostics: sessionPreparationDiagnostics
        )
        currentDocument = document
        let audioURL = sessionDirectoryURL.appendingPathComponent(
            "\(document.id.uuidString).m4a"
        )
        markers = []
        snapshot = TranscriptSnapshot()
        summary = nil
        isSummarizing = false
        savedAudioURL = nil
        startedAt = nil
        inputLevel = 0
        isInputLevelLow = false
        inputQualityMonitor.reset()
        captureSampleRate = nil
        lastCheckpointedFinalCount = 0
        lastCheckpointedTranslationCount = 0
        lastCheckpointedRefinedCount = 0
        isCompletingSession = false
        isHandlingFailure = false
        statusMessage = "正在检查麦克风权限"

        if processingMode == .highAccuracy {
            Task { [weak self] in
                _ = await self?.ensureEnhancedTranslationReady()
            }
        }

        snapshotTask = Task.detached { [weak self] in
            let stream = await pipeline.snapshots()
            for await value in stream {
                guard !Task.isCancelled else { return }
                await self?.receiveSnapshot(value)
            }
        }

        eventTask = Task.detached { [weak self] in
            for await event in engine.events {
                guard !Task.isCancelled else { return }
                await pipeline.consume(event)

                switch event {
                case .started:
                    await self?.receiveRecognitionStarted()
                case let .failed(message):
                    await self?.markFailed(message)
                case .finished:
                    await self?.receiveRecognitionFinished(
                        pipeline: pipeline,
                        course: course,
                        runsPostClassOptimization: shouldRunPostClassOptimization
                    )
                default:
                    break
                }
            }
        }

        let recordingCapture = capture as? any RecordingAudioCaptureEngine
        if let recordingCapture {
            recordingTask = Task.detached(priority: .userInitiated) { [weak self] in
                for await frame in recordingCapture.recordingFrames {
                    guard !Task.isCancelled else { return }
                    do {
                        try await audioBuffer.append(frame)
                    } catch {
                        await self?.receiveRecordingFailure(error.localizedDescription)
                        return
                    }
                }
            }
        }

        captureTask = Task.detached(priority: .userInitiated) { [weak self] in
            var inputLevelTask: Task<Void, Never>?
            defer { inputLevelTask?.cancel() }
            for await event in capture.events {
                guard !Task.isCancelled else { return }

                switch event {
                case let .started(sampleRate):
                    await self?.receiveCaptureStarted(sampleRate: sampleRate)
                case let .inputLevel(level):
                    inputLevelTask?.cancel()
                    inputLevelTask = Task { @MainActor [weak self] in
                        guard !Task.isCancelled else { return }
                        self?.receiveInputLevel(level)
                    }
                case let .frame(frame):
                    do {
                        if recordingCapture == nil {
                            try await audioBuffer.append(frame)
                        }
                        try await engine.accept(frame)
                    } catch {
                        await self?.markFailed(error.localizedDescription)
                        return
                    }
                case let .failed(message):
                    await self?.markFailed(message)
                    return
                case .stopped:
                    await self?.receiveCaptureStopped()
                }
            }
        }

        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.postClassAudioBuffer.reset()
                try await self.postClassAudioBuffer.prepareRecording(to: audioURL)
                try await self.stateMachine.transition(to: .preparing)
                self.lifecycleState = await self.stateMachine.currentState()

                guard await capture.requestPermission() else {
                    throw MicrophoneCaptureError.permissionDenied
                }
                if self.processingMode == .soniox {
                    self.statusMessage = "正在连接 Soniox 云端转写与翻译"
                } else if usesPrewarmedEngine {
                    self.statusMessage = "预热转写模型已复用"
                } else {
                    self.statusMessage = self.processingMode == .highAccuracy
                        ? "正在加载高精度模型（首次约 595 MB）"
                        : "正在加载省电模型（首次约 120 MB）"
                }
                try await engine.start(
                    configuration: RecognitionConfiguration(
                        course: course,
                        approvedTerms: approvedTerms,
                        translationTargetLanguage: self.processingMode == .soniox
                            ? "zh"
                            : nil
                    )
                )
                try Task.checkCancellation()
                try await capture.start()
                try Task.checkCancellation()
            } catch is CancellationError {
                await self.cancelPreparation()
            } catch {
                await self.markFailed(error.localizedDescription)
            }
        }
    }

    func stopSession() {
        stopSession(endedAt: Date(), completionNotice: nil)
    }

    private func stopSession(endedAt: Date, completionNotice: String?) {
        if lifecycleState == .finalizing, postClassTask != nil {
            skipPostClassOptimization()
            return
        }
        guard isActive else { return }

        if lifecycleState == .preparing {
            statusMessage = "正在取消"
            startupTask?.cancel()
            return
        }

        guard let recognitionEngine else {
            statusMessage = "正在保存课堂"
            return
        }
        guard !isStoppingSession else { return }
        isStoppingSession = true
        clearSleepCheckpoint()
        pendingCompletionNotice = completionNotice

        if let sessionStartedAt = currentDocument?.startedAt {
            currentDocument?.endedAt = max(endedAt, sessionStartedAt)
        }
        queueCheckpoint()
        statusMessage = "正在整理字幕"
        finalizationTask?.cancel()
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isStoppingSession = false
                self.finalizationTask = nil
            }
            do {
                await self.audioCapture?.stop()
                await self.recordingTask?.value
                await self.captureTask?.value
                _ = try await self.stateMachine.beginFinalizing()
                self.lifecycleState = await self.stateMachine.currentState()
                try await recognitionEngine.finalize()
            } catch {
                await self.markFailed(error.localizedDescription)
            }
        }
    }

    func handleSystemWillSleep(at date: Date = Date()) {
        guard lifecycleState == .running || lifecycleState == .paused,
              let sessionID = currentDocument?.id else {
            clearSleepCheckpoint()
            return
        }
        settingsDefaults.set(sessionID.uuidString, forKey: Self.sleepSessionIDKey)
        settingsDefaults.set(date, forKey: Self.sleepStartedAtKey)
        queueCheckpoint()
    }

    func handleSystemDidWake(at date: Date = Date()) {
        guard let checkpoint = storedSleepCheckpoint() else { return }
        clearSleepCheckpoint()
        guard checkpoint.sessionID == currentDocument?.id,
              lifecycleState == .running || lifecycleState == .paused,
              date.timeIntervalSince(checkpoint.startedAt) >= Self.sleepAutoStopInterval,
              let sessionStartedAt = currentDocument?.startedAt else { return }

        stopSession(
            endedAt: autoStopDate(
                sleepStartedAt: checkpoint.startedAt,
                sessionStartedAt: sessionStartedAt
            ),
            completionNotice: "笔记本休眠超过 10 分钟，课堂已自动结束"
        )
    }

    private func skipPostClassOptimization() {
        guard lifecycleState == .finalizing, postClassTask != nil else { return }
        statusMessage = "正在跳过课后优化并保存实时稿"
        postClassTask?.cancel()
    }

    func warmUpCourse() {
        guard canWarmUp else { return }
        enhancedModelReleaseTask?.cancel()
        enhancedModelReleaseTask = nil

        let preparedCourseName = CourseNameNormalizer.normalize(courseName)
        courseName = preparedCourseName
        let preparedMode = processingMode
        let recognitionProfile: LocalRecognitionProfile = preparedMode == .highAccuracy
            ? .highAccuracy
            : .energySaver
        let profile = profileStore.profile
        let course = Course(
            name: preparedCourseName,
            lecturerNames: lecturerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [lecturerName],
            lecturerAccent: lecturerAccent,
            recognitionTerms: parsedCourseTerms
        )

        isWarmingUp = true
        warmupDiagnostics = nil
        warmupDiagnosticsSignature = nil
        statusMessage = "正在准备课程术语"
        warmupTask = Task { [weak self] in
            guard let self else { return }
            await self.discardPrewarmedEngine()

            let preparationTask = Task {
                await self.coursePreparationService.prepare(
                    courseName: preparedCourseName,
                    profile: profile
                )
            }
            let translationTask = Task {
                preparedMode == .soniox
                    ? true
                    : await self.translationEngine.prepare()
            }
            self.coursePreparationTask = preparationTask
            self.translationPreparationTask = translationTask
            self.refinementPreparationTask = nil
            let engine: (any SpeechRecognitionEngine)? = preparedMode == .soniox
                ? nil
                : recognitionEngineFactory(recognitionProfile)

            do {
                if let engine {
                    self.statusMessage = "正在预热实时转写模型"
                    try await engine.start(
                        configuration: RecognitionConfiguration(course: course)
                    )
                    try Task.checkCancellation()
                }

                let preparation = await preparationTask.value
                let translationReady = await translationTask.value
                let refinementReady: Bool
                if preparedMode == .highAccuracy {
                    self.statusMessage = "正在加载本地精译模型"
                    let refinementTask = Task {
                        await self.refinementTranslationEngine.prepare { [weak self] progress in
                            let percent = Int((progress.fractionCompleted * 100).rounded())
                            Task { @MainActor [weak self] in
                                guard self?.isWarmingUp == true else { return }
                                self?.statusMessage = "正在准备本地精译模型 \(percent)%"
                            }
                        }
                    }
                    self.refinementPreparationTask = refinementTask
                    refinementReady = await refinementTask.value
                } else {
                    refinementReady = false
                }
                try Task.checkCancellation()
                guard self.courseName.trimmingCharacters(in: .whitespacesAndNewlines)
                    == preparedCourseName,
                      self.processingMode == preparedMode else {
                    throw CancellationError()
                }

                self.mergePreparedTerms(preparation.terms)
                let actualTerms = self.parsedCourseTerms
                let diagnostics = SessionPreparationDiagnostics(
                    asrModelReady: preparedMode != .soniox
                        || self.sonioxCredentialStore.hasAPIKey,
                    quickTranslationReady: translationReady,
                    enhancedTranslationReady: refinementReady,
                    usedFoundationModel: preparation.usedFoundationModel,
                    generatedTermCount: preparation.generatedTermCount,
                    terms: actualTerms
                )
                self.prewarmedEngine = engine
                self.prewarmedSignature = self.currentWarmupSignature
                self.warmupDiagnostics = diagnostics
                self.warmupDiagnosticsSignature = self.currentWarmupSignature
                self.isWarmingUp = false
                self.warmupTask = nil
                self.coursePreparationTask = nil
                self.translationPreparationTask = nil
                self.refinementPreparationTask = nil
                self.isEnhancedTranslationReady = refinementReady

                if preparedMode == .soniox, !self.sonioxCredentialStore.hasAPIKey {
                    self.statusMessage = "课程术语已准备，请配置 Soniox API Key"
                } else if preparedMode == .soniox {
                    self.statusMessage = "Soniox 双语上下文已准备，术语 \(actualTerms.count) 个"
                } else if !translationReady {
                    self.statusMessage = "转写已预热，翻译语言包尚未就绪"
                } else if preparedMode == .highAccuracy, !refinementReady {
                    self.statusMessage = "预热完成，本地精译未就绪，将使用快速翻译"
                } else if preparedMode == .highAccuracy {
                    self.statusMessage = "预热完成，转写与高质量精译已就绪，术语 \(actualTerms.count) 个"
                } else if preparation.usedFoundationModel {
                    self.statusMessage = "预热完成，候选术语 \(actualTerms.count) 个"
                } else {
                    self.statusMessage = "预热完成，课程术语 \(actualTerms.count) 个"
                }
            } catch is CancellationError {
                preparationTask.cancel()
                translationTask.cancel()
                self.refinementPreparationTask?.cancel()
                try? await engine?.finalize()
                self.isWarmingUp = false
                self.warmupTask = nil
                self.coursePreparationTask = nil
                self.translationPreparationTask = nil
                self.refinementPreparationTask = nil
                self.statusMessage = "预热已取消"
            } catch {
                preparationTask.cancel()
                translationTask.cancel()
                self.refinementPreparationTask?.cancel()
                try? await engine?.finalize()
                self.isWarmingUp = false
                self.warmupTask = nil
                self.coursePreparationTask = nil
                self.translationPreparationTask = nil
                self.refinementPreparationTask = nil
                self.statusMessage = "预热失败：\(error.localizedDescription)"
            }
        }
    }

    func cancelWarmup() {
        guard isWarmingUp else { return }
        statusMessage = "正在取消预热"
        coursePreparationTask?.cancel()
        translationPreparationTask?.cancel()
        refinementPreparationTask?.cancel()
        translationEngine.cancelPreparation()
        warmupTask?.cancel()
    }

    func refreshInputDevices() {
        guard !isActive, !isTestingMicrophone else { return }
        let devices = MicrophoneDeviceCatalog.availableInputDevices()
        availableInputDevices = devices
        guard !devices.contains(where: { $0.uid == selectedInputDeviceUID }) else { return }
        selectedInputDeviceUID = MicrophoneDeviceCatalog.defaultInputDeviceUID()
            ?? devices.first?.uid
    }

    func testSelectedMicrophone() {
        guard lifecycleState == .idle, !isWarmingUp else { return }
        if isTestingMicrophone {
            microphoneTestTask?.cancel()
            return
        }

        microphoneTestURL.map { try? FileManager.default.removeItem(at: $0) }
        microphoneTestURL = nil
        isTestingMicrophone = true
        statusMessage = "正在录制 15 秒麦克风试听"
        let selectedUID = selectedInputDeviceUID
        microphoneTestTask = Task { [weak self] in
            guard let self else { return }
            let capture = self.audioCaptureFactory(selectedUID)
            guard let recordingCapture = capture as? any RecordingAudioCaptureEngine else {
                self.isTestingMicrophone = false
                self.statusMessage = "当前麦克风不支持试听"
                return
            }
            let buffer = SessionAudioBuffer()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "LingoSlate-Microphone-Test-\(UUID().uuidString).m4a"
            )
            do {
                try await buffer.prepareRecording(to: url)
                let recordingTask = Task {
                    for await frame in recordingCapture.recordingFrames {
                        try? await buffer.append(frame)
                    }
                }
                try await capture.start()
                try await Task.sleep(for: .seconds(15))
                await capture.stop()
                await recordingTask.value
                guard let savedURL = try await buffer.finishWriting() else {
                    throw SessionAudioBufferError.noAudio
                }
                let diagnostics = await capture.captureDiagnostics()
                self.microphoneTestURL = savedURL
                self.statusMessage = "试听录制完成：\(diagnostics?.inputDeviceName ?? "麦克风")"
                NSWorkspace.shared.open(savedURL)
            } catch is CancellationError {
                await capture.stop()
                await buffer.reset()
                self.statusMessage = "已取消麦克风试听"
            } catch {
                await capture.stop()
                await buffer.reset()
                self.statusMessage = "麦克风试听失败：\(error.localizedDescription)"
            }
            self.isTestingMicrophone = false
            self.microphoneTestTask = nil
        }
    }

    func addMarker(_ kind: MarkerKind) {
        guard let startedAt, canAddMarker else { return }
        let marker = SessionMarker(
            timestamp: max(0, Date().timeIntervalSince(startedAt)),
            kind: kind
        )
        markers.append(marker)
        currentDocument?.markers = markers
        queueCheckpoint()
    }

    func correctSegment(id: UUID, sourceText: String) {
        guard let pipeline,
              let original = snapshot.finalSegments.first(where: { $0.id == id }),
              let course = currentDocument?.configuration.course else { return }
        correctionStore.record(
            heard: original.sourceText,
            corrected: sourceText,
            course: course
        )
        Task { [weak self] in
            guard let self else { return }
            await pipeline.correctSegment(id: id, sourceText: sourceText)
            self.snapshot = await pipeline.currentSnapshot()
            self.currentDocument?.segments = self.snapshot.finalSegments
            self.queueCheckpoint()
        }
    }

    func playSavedAudio() {
        guard let savedAudioURL else { return }
        NSWorkspace.shared.open(savedAudioURL)
    }

    func revealSavedAudio() {
        guard let savedAudioURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedAudioURL])
    }

    func resetForNextSession() {
        guard !isActive else { return }
        warmupTask?.cancel()
        coursePreparationTask?.cancel()
        translationPreparationTask?.cancel()
        refinementPreparationTask?.cancel()
        startupTask?.cancel()
        eventTask?.cancel()
        captureTask?.cancel()
        recordingTask?.cancel()
        snapshotTask?.cancel()
        postClassTask?.cancel()
        finalizationTask?.cancel()
        checkpointTask?.cancel()
        startupTask = nil
        eventTask = nil
        captureTask = nil
        recordingTask = nil
        snapshotTask = nil
        postClassTask = nil
        finalizationTask = nil
        checkpointTask = nil
        warmupTask = nil
        coursePreparationTask = nil
        translationPreparationTask = nil
        refinementPreparationTask = nil
        pipeline = nil
        recognitionEngine = nil
        audioCapture = nil
        currentDocument = nil
        snapshot = TranscriptSnapshot()
        summary = nil
        isSummarizing = false
        savedAudioURL = nil
        warmupDiagnostics = nil
        warmupDiagnosticsSignature = nil
        markers = []
        startedAt = nil
        inputLevel = 0
        isInputLevelLow = false
        inputQualityMonitor.reset()
        captureSampleRate = nil
        lastCheckpointedFinalCount = 0
        lastCheckpointedTranslationCount = 0
        lastCheckpointedRefinedCount = 0
        isCompletingSession = false
        isHandlingFailure = false
        isStoppingSession = false
        pendingCompletionNotice = nil
        clearSleepCheckpoint()
        statusMessage = "就绪"

        Task {
            await postClassAudioBuffer.reset()
            let current = await stateMachine.currentState()
            if current == .completed || isFailure(current) {
                try? await stateMachine.transition(to: .idle)
            }
            lifecycleState = await stateMachine.currentState()
        }
    }

    private func markRunning() async {
        do {
            if await stateMachine.currentState() == .preparing {
                try await stateMachine.transition(to: .running)
            }
            lifecycleState = await stateMachine.currentState()
            let captureStartedAt = Date()
            startedAt = captureStartedAt
            currentDocument?.startedAt = captureStartedAt
        } catch {
            await markFailed(error.localizedDescription)
        }
    }

    private func receiveSnapshot(_ value: TranscriptSnapshot) {
        snapshot = value
        let finalCount = value.finalSegments.count
        let translationCount = value.finalSegments.lazy.filter {
            $0.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.count
        let refinedCount = value.finalSegments.lazy.filter {
            $0.translationProvider == self.refinementTranslationEngine.identifier
        }.count
        guard finalCount != lastCheckpointedFinalCount
                || translationCount != lastCheckpointedTranslationCount
                || refinedCount != lastCheckpointedRefinedCount else { return }
        lastCheckpointedFinalCount = finalCount
        lastCheckpointedTranslationCount = translationCount
        lastCheckpointedRefinedCount = refinedCount
        queueCheckpoint()
    }

    private func receiveRecognitionStarted() {
        if processingMode == .soniox, lifecycleState == .running {
            statusMessage = "Soniox 网络已恢复，正在云端转写与翻译"
            return
        }
        statusMessage = processingMode == .soniox
            ? "Soniox 双语服务已就绪，正在连接麦克风"
            : "模型已就绪，正在连接麦克风"
    }

    private func receiveRecognitionFinished(
        pipeline: SubtitlePipeline,
        course: Course,
        runsPostClassOptimization: Bool
    ) async {
        recognitionEngine = nil
        await updateAudioCaptureDiagnostics()
        audioCapture = nil
        snapshot = await pipeline.currentSnapshot()
        do {
            try await persistStoppedSession()
        } catch {
            await markFailed(error.localizedDescription)
            return
        }
        if runsPostClassOptimization {
            statusMessage = "正在准备课后高精度处理"
            postClassTask?.cancel()
            postClassTask = Task(priority: .utility) { [weak self] in
                await Task.yield()
                guard let self else { return }
                guard !Task.isCancelled else {
                    await self.completeSession(translationOptimizationCompleted: false)
                    self.postClassTask = nil
                    return
                }
                await self.runPostClassOptimization(
                    pipeline: pipeline,
                    configuration: RecognitionConfiguration(course: course)
                )
            }
        } else {
            await completeSession()
        }
    }

    private func receiveCaptureStarted(sampleRate: Double) async {
        captureSampleRate = sampleRate
        await markRunning()
        statusMessage = processingMode == .soniox
            ? "正在云端转写与翻译"
            : "正在收听"
    }

    private func receiveInputLevel(_ level: Float) {
        inputLevel = level
        isInputLevelLow = inputQualityMonitor.record(
            level: level,
            at: ProcessInfo.processInfo.systemUptime
        )
    }

    private func receiveCaptureStopped() {
        if currentDocument?.endedAt == nil {
            currentDocument?.endedAt = Date()
        }
        queueCheckpoint()
        inputLevel = 0
        isInputLevelLow = false
        inputQualityMonitor.reset()
    }

    private func receiveRecordingFailure(_ message: String) async {
        recordingTask = nil
        await markFailed(message)
    }

    private func markFailed(_ message: String) async {
        guard !isHandlingFailure else { return }
        isHandlingFailure = true
        defer { isHandlingFailure = false }
        let sleepAutoStopDate = pendingSleepAutoStopDate(at: Date())

        await audioCapture?.stop()
        await recordingTask?.value
        await updateAudioCaptureDiagnostics()
        if let pipeline {
            snapshot = await pipeline.currentSnapshot()
        }
        if var document = currentDocument {
            document.endedAt = sleepAutoStopDate ?? document.endedAt ?? Date()
            document.processedAt = Date()
            document.segments = snapshot.finalSegments
            document.markers = markers
            document.failureMessage = message
            document.isPostProcessingComplete = false
            if let audioURL = try? await savedAudioURL(for: document) {
                document.audioFileName = audioURL.lastPathComponent
                savedAudioURL = audioURL
            }
            currentDocument = document
            await checkpointTask?.value
            try? await sessionStore.save(document)
        }
        await teardownSessionGraph(finalizeRecognition: false)
        await postClassAudioBuffer.reset()
        let current = await stateMachine.currentState()
        if current != .idle {
            try? await stateMachine.transition(to: .failed(message: message))
        }
        lifecycleState = await stateMachine.currentState()
        inputLevel = 0
        isInputLevelLow = false
        inputQualityMonitor.reset()
        isSummarizing = false
        statusMessage = sleepAutoStopDate == nil
            ? message
            : "笔记本休眠超过 10 分钟，课堂已自动结束；\(message)"
        clearSleepCheckpoint()
        isStoppingSession = false
    }

    private func completeSession(translationOptimizationCompleted: Bool = true) async {
        guard !isCompletingSession else { return }
        isCompletingSession = true
        defer { isCompletingSession = false }

        let current = await stateMachine.currentState()
        if isFailure(current) { return }

        var audioSaveFailureMessage: String?
        do {
            _ = try await stateMachine.beginFinalizing()
            lifecycleState = await stateMachine.currentState()

            if let pipeline {
                let drained = await pipeline.finishPendingTranslations(timeout: .seconds(30))
                if drained, !Task.isCancelled {
                    await pipeline.retranslateMissing()
                    _ = await pipeline.finishPendingTranslations(timeout: .seconds(15))
                }
                snapshot = await pipeline.currentSnapshot()
            }

            if var document = currentDocument {
                document.endedAt = document.endedAt ?? Date()
                document.processedAt = Date()
                document.segments = snapshot.finalSegments
                document.markers = markers
                document.failureMessage = nil
                let refinableSegments = snapshot.finalSegments.filter {
                    $0.translationExclusionReason == nil
                }
                let refinementComplete = document.configuration.processingMode != .highAccuracy
                    || refinableSegments.allSatisfy {
                        $0.translationProvider == refinementTranslationEngine.identifier
                    }
                document.isPostProcessingComplete = translationOptimizationCompleted
                    && refinementComplete

                if document.configuration.audioRetention == .keep {
                    statusMessage = "正在完成本地录音"
                    do {
                        if let audioURL = try await savedAudioURL(for: document) {
                            document.audioFileName = audioURL.lastPathComponent
                            savedAudioURL = audioURL
                        }
                    } catch {
                        audioSaveFailureMessage = error.localizedDescription
                    }
                }

                if !Task.isCancelled {
                    statusMessage = "正在生成课后摘要"
                    isSummarizing = true
                    do {
                        let generatedSummary = try await summaryEngine.summarize(document)
                        document.summary = generatedSummary
                        summary = generatedSummary
                    } catch {
                        document.summary = nil
                        summary = nil
                    }
                }
                isSummarizing = false
                await checkpointTask?.value
                try await sessionStore.save(document)
                currentDocument = document
            }

            if await stateMachine.currentState() == .finalizing {
                try await stateMachine.transition(to: .completed)
            }
            lifecycleState = await stateMachine.currentState()
            await postClassAudioBuffer.reset()
            if let audioSaveFailureMessage {
                statusMessage = "双语文本已保存，但录音保存失败：\(audioSaveFailureMessage)"
            } else if snapshot.finalSegments.isEmpty, savedAudioURL != nil {
                statusMessage = "录音已保存到本机，未识别到语音"
            } else if snapshot.finalSegments.isEmpty {
                statusMessage = "会话已保存到本机，未捕获到语音"
            } else if summary?.isEmpty == false, savedAudioURL != nil {
                statusMessage = "录音、摘要与双语文本已保存到本机"
            } else if savedAudioURL != nil {
                statusMessage = "录音与双语文本已保存到本机"
            } else if summary?.isEmpty == false {
                statusMessage = "摘要与双语文本已保存到本机"
            } else {
                statusMessage = "双语文本已保存到本机"
            }
            if currentDocument?.isPostProcessingComplete == false {
                statusMessage += "；部分内容仍为快速翻译"
            }
            if let diagnostics = currentDocument?.audioCaptureDiagnostics {
                let recognitionDrops = diagnostics.recognitionDroppedFrameCount
                let recordingDrops = diagnostics.recordingDroppedFrameCount
                if recognitionDrops > 0 || recordingDrops > 0 {
                    statusMessage += "；音频拥堵"
                    if recognitionDrops > 0 {
                        statusMessage += "，转写丢帧 \(recognitionDrops) 次"
                    }
                    if recordingDrops > 0 {
                        statusMessage += "，录音丢帧 \(recordingDrops) 次"
                    }
                }
            }
            if let pendingCompletionNotice {
                statusMessage = "\(pendingCompletionNotice)；\(statusMessage)"
                self.pendingCompletionNotice = nil
            }
            clearSleepCheckpoint()
            if currentDocument?.configuration.processingMode == .highAccuracy {
                scheduleEnhancedModelRelease()
            }
            isStoppingSession = false
        } catch {
            isSummarizing = false
            await markFailed(error.localizedDescription)
        }
    }

    private func cancelPreparation() async {
        await teardownSessionGraph(finalizeRecognition: true)
        await postClassAudioBuffer.reset()
        let current = await stateMachine.currentState()
        if current == .preparing {
            try? await stateMachine.transition(to: .idle)
        }
        lifecycleState = await stateMachine.currentState()
        inputLevel = 0
        isInputLevelLow = false
        inputQualityMonitor.reset()
        statusMessage = "已取消"
    }

    private func persistStoppedSession() async throws {
        guard var document = currentDocument else { return }
        document.endedAt = document.endedAt ?? Date()
        document.segments = snapshot.finalSegments
        document.markers = markers
        document.isPostProcessingComplete = false
        if let audioURL = try await savedAudioURL(for: document) {
            document.audioFileName = audioURL.lastPathComponent
            savedAudioURL = audioURL
        }
        currentDocument = document
        await checkpointTask?.value
        try await sessionStore.save(document)
    }

    private func savedAudioURL(for document: SessionDocument) async throws -> URL? {
        let fileManager = FileManager.default
        let expectedFileName = "\(document.id.uuidString).m4a"
        if let savedAudioURL,
           savedAudioURL.lastPathComponent == expectedFileName,
           fileManager.fileExists(atPath: savedAudioURL.path) {
            return savedAudioURL
        }
        if let audioFileName = document.audioFileName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !audioFileName.isEmpty {
            let documentAudioURL = sessionDirectoryURL.appendingPathComponent(audioFileName)
            if fileManager.fileExists(atPath: documentAudioURL.path) {
                return documentAudioURL
            }
        }
        let expectedAudioURL = sessionDirectoryURL.appendingPathComponent(expectedFileName)
        if fileManager.fileExists(atPath: expectedAudioURL.path) {
            return expectedAudioURL
        }
        guard document.configuration.audioRetention == .keep else { return nil }
        return try await postClassAudioBuffer.finishWriting()
    }

    private func queueCheckpoint() {
        guard var document = currentDocument else { return }
        document.segments = snapshot.finalSegments
        document.markers = markers
        document.isPostProcessingComplete = false
        currentDocument = document

        let previousTask = checkpointTask
        let store = sessionStore
        checkpointTask = Task {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            try? await store.save(document)
        }
    }

    private func storedSleepCheckpoint() -> (sessionID: UUID, startedAt: Date)? {
        guard let sessionIDValue = settingsDefaults.string(
            forKey: Self.sleepSessionIDKey
        ), let sessionID = UUID(uuidString: sessionIDValue),
        let startedAt = settingsDefaults.object(
            forKey: Self.sleepStartedAtKey
        ) as? Date else { return nil }
        return (sessionID, startedAt)
    }

    private func clearSleepCheckpoint() {
        settingsDefaults.removeObject(forKey: Self.sleepSessionIDKey)
        settingsDefaults.removeObject(forKey: Self.sleepStartedAtKey)
    }

    private func autoStopDate(
        sleepStartedAt: Date,
        sessionStartedAt: Date
    ) -> Date {
        max(
            sleepStartedAt.addingTimeInterval(Self.sleepAutoStopInterval),
            sessionStartedAt
        )
    }

    private func pendingSleepAutoStopDate(at date: Date) -> Date? {
        guard let checkpoint = storedSleepCheckpoint(),
              checkpoint.sessionID == currentDocument?.id,
              date.timeIntervalSince(checkpoint.startedAt) >= Self.sleepAutoStopInterval,
              let sessionStartedAt = currentDocument?.startedAt else { return nil }
        return autoStopDate(
            sleepStartedAt: checkpoint.startedAt,
            sessionStartedAt: sessionStartedAt
        )
    }

    private func teardownSessionGraph(finalizeRecognition: Bool) async {
        let capture = audioCapture
        let engine = recognitionEngine
        startupTask?.cancel()
        eventTask?.cancel()
        captureTask?.cancel()
        recordingTask?.cancel()
        snapshotTask?.cancel()
        finalizationTask?.cancel()
        startupTask = nil
        eventTask = nil
        captureTask = nil
        recordingTask = nil
        snapshotTask = nil
        finalizationTask = nil
        audioCapture = nil
        recognitionEngine = nil
        pipeline = nil
        await capture?.stop()
        if finalizeRecognition {
            try? await engine?.finalize()
        } else if let engine {
            Task {
                try? await engine.finalize()
            }
        }
    }

    private func updateAudioCaptureDiagnostics() async {
        guard let diagnostics = await audioCapture?.captureDiagnostics() else { return }
        currentDocument?.audioCaptureDiagnostics = diagnostics
    }

    private func isFailure(_ state: SessionLifecycleState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private var parsedCourseTerms: [String] {
        var seen: Set<String> = []
        return courseTermsText.split { character in
            character == "," || character == ";" || character.isNewline
        }.compactMap { rawTerm in
            let term = String(rawTerm).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return term
        }
    }

    private func takePrewarmedEngine(
        for signature: RecognitionWarmupSignature
    ) -> (any SpeechRecognitionEngine)? {
        guard prewarmedSignature == signature else {
            let staleEngine = prewarmedEngine
            prewarmedEngine = nil
            prewarmedSignature = nil
            warmupDiagnostics = nil
            warmupDiagnosticsSignature = nil
            if let staleEngine {
                Task { try? await staleEngine.finalize() }
            }
            return nil
        }

        let engine = prewarmedEngine
        prewarmedEngine = nil
        prewarmedSignature = nil
        return engine
    }

    private func discardPrewarmedEngine() async {
        let engine = prewarmedEngine
        prewarmedEngine = nil
        prewarmedSignature = nil
        warmupDiagnostics = nil
        warmupDiagnosticsSignature = nil
        try? await engine?.finalize()
    }

    private func scheduleEnhancedModelRelease() {
        enhancedModelReleaseTask?.cancel()
        enhancedModelReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15 * 60))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.refinementTranslationEngine.release()
            self.isEnhancedTranslationReady = false
            self.enhancedModelReleaseTask = nil
        }
    }

    private func releaseEnhancedTranslationModel() async {
        enhancedModelReleaseTask?.cancel()
        enhancedModelReleaseTask = nil
        refinementPreparationTask?.cancel()
        refinementPreparationTask = nil
        await refinementTranslationEngine.release()
        isEnhancedTranslationReady = false
    }

    private func ensureEnhancedTranslationReady() async -> Bool {
        if isEnhancedTranslationReady { return true }
        if let refinementPreparationTask {
            let ready = await refinementPreparationTask.value
            isEnhancedTranslationReady = ready
            return ready
        }

        let task = Task {
            await refinementTranslationEngine.prepare()
        }
        refinementPreparationTask = task
        let ready = await task.value
        refinementPreparationTask = nil
        isEnhancedTranslationReady = ready
        if var diagnostics = currentDocument?.preparationDiagnostics {
            diagnostics.enhancedTranslationReady = ready
            currentDocument?.preparationDiagnostics = diagnostics
            queueCheckpoint()
        }
        return ready
    }

    private var currentWarmupSignature: RecognitionWarmupSignature {
        RecognitionWarmupSignature(
            courseName: courseName.trimmingCharacters(in: .whitespacesAndNewlines),
            recognitionTerms: parsedCourseTerms,
            processingMode: processingMode,
            profile: processingMode == .highAccuracy ? .highAccuracy : .energySaver
        )
    }

    private func mergePreparedTerms(_ preparedTerms: [String]) {
        var seen: Set<String> = []
        let mergedTerms: [String] = (parsedCourseTerms + preparedTerms).compactMap { term in
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return term
        }
        courseTermsText = mergedTerms.joined(separator: ", ")
    }

    private func runPostClassOptimization(
        pipeline: SubtitlePipeline,
        configuration: RecognitionConfiguration
    ) async {
        guard !(await postClassAudioBuffer.isEmpty) else {
            await completeSession(translationOptimizationCompleted: false)
            return
        }

        statusMessage = "正在确认本地精译模型"
        let enhancedTranslationReady = await ensureEnhancedTranslationReady()
        guard !Task.isCancelled else {
            await completeSession(translationOptimizationCompleted: false)
            postClassTask = nil
            return
        }

        statusMessage = enhancedTranslationReady
            ? "正在生成课后高精度稿"
            : "精译模型未就绪，正在保存快速翻译稿"
        let offlineProfile = FluidAudioStreamingProfile.unifiedOffline15s
        let engine = FluidAudioStreamingRecognitionEngine(profile: offlineProfile)
        let collector = OfflineTranscriptCollector()
        let offlineEventTask = Task {
            for await event in engine.events {
                guard !Task.isCancelled else { return }
                await collector.consume(event)
            }
        }

        var translationOptimizationCompleted = false
        do {
            try await engine.start(configuration: configuration)
            try await postClassAudioBuffer.replay(into: engine)
            try await engine.finalize()
            await offlineEventTask.value

            let timedChunks = await collector.chunks
            if !timedChunks.isEmpty {
                let replacementCompleted = await pipeline.replaceFinalTranscript(
                    with: timedChunks,
                    provider: offlineProfile.providerIdentifier,
                    maximumWordsPerSegment: 36,
                    progress: { [weak self] completed, total in
                        Task { @MainActor [weak self] in
                            guard total > 0 else { return }
                            self?.statusMessage = "正在优化课后双语稿 \(completed)/\(total)"
                        }
                    }
                )
                let optimizedSnapshot = await pipeline.currentSnapshot()
                translationOptimizationCompleted = replacementCompleted
                    && enhancedTranslationReady
                    && optimizedSnapshot.finalSegments
                        .filter { $0.translationExclusionReason == nil }
                        .allSatisfy {
                            $0.translationProvider == refinementTranslationEngine.identifier
                        }
            }
        } catch {
            offlineEventTask.cancel()
            try? await engine.finalize()
            statusMessage = "课后高精度处理失败，正在保存实时稿"
        }

        await completeSession(
            translationOptimizationCompleted: translationOptimizationCompleted
        )
        postClassTask = nil
    }
}

private struct RecognitionWarmupSignature: Equatable {
    var courseName: String
    var recognitionTerms: [String]
    var processingMode: ProcessingMode
    var profile: LocalRecognitionProfile
}

private actor OfflineTranscriptCollector {
    private var finalParts: [TimedTranscriptChunk] = []

    var chunks: [TimedTranscriptChunk] {
        finalParts
    }

    func consume(_ event: RecognitionEvent) {
        guard case let .final(_, text, startTime, endTime, _, _) = event else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        finalParts.append(
            TimedTranscriptChunk(
                text: trimmedText,
                startTime: startTime,
                endTime: endTime
            )
        )
    }
}
