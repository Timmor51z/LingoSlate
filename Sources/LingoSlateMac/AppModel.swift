import LingoSlateAudio
import LingoSlateCore
import LingoSlateTranslation
import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var courseName = ""
    @Published var courseTermsText = ""
    @Published var sessionKind: SessionKind = .lecture
    @Published var processingMode: ProcessingMode = .highAccuracy
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

    private let stateMachine = SessionStateMachine()
    private let sessionDirectoryURL: URL
    private let sessionStore: SessionStore
    private let postClassAudioBuffer = SessionAudioBuffer()
    private let profileStore: UserProfileStore
    private let coursePreparationService = CoursePreparationService()
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
    private var snapshotTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    private var coursePreparationTask: Task<CoursePreparationResult, Never>?
    private var translationPreparationTask: Task<Bool, Never>?
    private var refinementPreparationTask: Task<Bool, Never>?
    private var prewarmedEngine: (any SpeechRecognitionEngine)?
    private var prewarmedSignature: RecognitionWarmupSignature?

    init(profileStore: UserProfileStore = UserProfileStore()) {
        let sessionDirectoryURL = Self.sessionDirectory()
        self.profileStore = profileStore
        self.sessionDirectoryURL = sessionDirectoryURL
        sessionStore = SessionStore(directoryURL: sessionDirectoryURL)
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

    var canStart: Bool {
        lifecycleState == .idle
            && audioSource == .microphone
            && !isWarmingUp
    }

    var canWarmUp: Bool {
        lifecycleState == .idle
            && !isWarmingUp
    }

    var isCourseWarm: Bool {
        prewarmedEngine != nil && prewarmedSignature == currentWarmupSignature
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

    func startSession() {
        guard canStart else { return }

        let course = Course(
            name: courseName,
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
                refinement: refinementTranslationEngine
            )
            : translationEngine
        let pipeline = SubtitlePipeline(
            course: course,
            translationEngine: sessionTranslationEngine,
            approvedTerms: RegionalAcademicGlossary.approvedTerms(
                for: profileStore.profile
            )
        )
        translationEngine.activate()
        let recognitionProfile: LocalRecognitionProfile = processingMode == .highAccuracy
            ? .highAccuracy
            : .energySaver
        let prewarmedEngine = takePrewarmedEngine(for: currentWarmupSignature)
        let engine = prewarmedEngine
            ?? LocalRecognitionEngineFactory.make(profile: recognitionProfile)
        let usesPrewarmedEngine = prewarmedEngine != nil
        let capture = MicrophoneAudioCapture()
        let shouldRunPostClassOptimization = processingMode == .highAccuracy

        self.pipeline = pipeline
        recognitionEngine = engine
        audioCapture = capture
        currentDocument = SessionDocument(configuration: configuration)
        markers = []
        snapshot = TranscriptSnapshot()
        summary = nil
        isSummarizing = false
        savedAudioURL = nil
        startedAt = nil
        inputLevel = 0
        captureSampleRate = nil
        statusMessage = "正在检查麦克风权限"

        snapshotTask = Task { [weak self] in
            let stream = await pipeline.snapshots()
            for await value in stream {
                guard !Task.isCancelled else { return }
                self?.snapshot = value
            }
        }

        eventTask = Task { [weak self] in
            for await event in engine.events {
                guard !Task.isCancelled else { return }
                await pipeline.consume(event)

                switch event {
                case .started:
                    self?.statusMessage = "模型已就绪，正在连接麦克风"
                case let .failed(message):
                    await self?.markFailed(message)
                case .finished:
                    if shouldRunPostClassOptimization {
                        await self?.runPostClassOptimization(
                            pipeline: pipeline,
                            configuration: RecognitionConfiguration(course: course)
                        )
                    } else {
                        await self?.completeSession()
                    }
                default:
                    break
                }
            }
        }

        captureTask = Task { [weak self] in
            for await event in capture.events {
                guard !Task.isCancelled else { return }

                switch event {
                case let .started(sampleRate):
                    self?.captureSampleRate = sampleRate
                    await self?.markRunning()
                    self?.statusMessage = "正在收听"
                case let .inputLevel(level):
                    self?.inputLevel = level
                case let .frame(frame):
                    do {
                        await self?.postClassAudioBuffer.append(frame)
                        try await engine.accept(frame)
                    } catch {
                        await self?.markFailed(error.localizedDescription)
                        return
                    }
                case let .failed(message):
                    await self?.markFailed(message)
                    return
                case .stopped:
                    self?.inputLevel = 0
                }
            }
        }

        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.postClassAudioBuffer.reset()
                try await self.stateMachine.transition(to: .preparing)
                self.lifecycleState = await self.stateMachine.currentState()

                guard await capture.requestPermission() else {
                    throw MicrophoneCaptureError.permissionDenied
                }
                if usesPrewarmedEngine {
                    self.statusMessage = "预热模型已就绪"
                } else {
                    self.statusMessage = self.processingMode == .highAccuracy
                        ? "正在加载高精度模型（首次约 595 MB）"
                        : "正在加载省电模型（首次约 120 MB）"
                }
                try await engine.start(configuration: RecognitionConfiguration(course: course))
                try Task.checkCancellation()
                try await capture.start()
            } catch is CancellationError {
                await self.cancelPreparation()
            } catch {
                await self.markFailed(error.localizedDescription)
            }
        }
    }

    func stopSession() {
        guard isActive, let recognitionEngine else { return }

        if lifecycleState == .preparing {
            statusMessage = "正在取消"
            startupTask?.cancel()
            return
        }

        statusMessage = "正在整理字幕"
        Task {
            do {
                await audioCapture?.stop()
                let current = await stateMachine.currentState()
                if current == .running || current == .paused {
                    try await stateMachine.transition(to: .finalizing)
                    lifecycleState = await stateMachine.currentState()
                }
                try await recognitionEngine.finalize()
            } catch {
                await markFailed(error.localizedDescription)
            }
        }
    }

    func warmUpCourse() {
        guard canWarmUp else { return }

        let preparedCourseName = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let preparedMode = processingMode
        let recognitionProfile: LocalRecognitionProfile = preparedMode == .highAccuracy
            ? .highAccuracy
            : .energySaver
        let profile = profileStore.profile
        let course = Course(
            name: preparedCourseName,
            recognitionTerms: parsedCourseTerms
        )

        isWarmingUp = true
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
                await self.translationEngine.prepare()
            }
            let refinementTask = Task {
                guard preparedMode == .highAccuracy else { return false }
                return await self.refinementTranslationEngine.prepare { [weak self] progress in
                    let percent = Int((progress.fractionCompleted * 100).rounded())
                    Task { @MainActor [weak self] in
                        guard self?.isWarmingUp == true else { return }
                        self?.statusMessage = "正在准备本地精译模型 \(percent)%"
                    }
                }
            }
            self.coursePreparationTask = preparationTask
            self.translationPreparationTask = translationTask
            self.refinementPreparationTask = refinementTask
            let engine = LocalRecognitionEngineFactory.make(profile: recognitionProfile)

            do {
                self.statusMessage = "正在预热实时转写模型"
                try await engine.start(
                    configuration: RecognitionConfiguration(course: course)
                )
                try Task.checkCancellation()

                var offlineModelReady = true
                if preparedMode == .highAccuracy {
                    self.statusMessage = "正在确认课后高精度模型"
                    offlineModelReady = await self.prepareOfflineModel(for: course)
                    try Task.checkCancellation()
                }

                let preparation = await preparationTask.value
                let translationReady = await translationTask.value
                if preparedMode == .highAccuracy {
                    self.statusMessage = "正在加载本地精译模型"
                }
                let refinementReady = await refinementTask.value
                try Task.checkCancellation()
                guard self.courseName.trimmingCharacters(in: .whitespacesAndNewlines)
                    == preparedCourseName,
                      self.processingMode == preparedMode else {
                    throw CancellationError()
                }

                self.mergePreparedTerms(preparation.terms)
                self.prewarmedEngine = engine
                self.prewarmedSignature = self.currentWarmupSignature
                self.isWarmingUp = false
                self.warmupTask = nil
                self.coursePreparationTask = nil
                self.translationPreparationTask = nil
                self.refinementPreparationTask = nil
                self.isEnhancedTranslationReady = refinementReady

                if !translationReady {
                    self.statusMessage = "转写已预热，翻译语言包尚未就绪"
                } else if preparedMode == .highAccuracy, !refinementReady {
                    self.statusMessage = "预热完成，本地精译未就绪，将使用快速翻译"
                } else if preparedMode == .highAccuracy, !offlineModelReady {
                    self.statusMessage = "实时模型已预热，课后模型将在结束时加载"
                } else if preparedMode == .highAccuracy {
                    self.statusMessage = "预热完成，高质量本地精译已就绪"
                } else if preparation.usedFoundationModel {
                    self.statusMessage = "预热完成，候选术语已生成"
                } else {
                    self.statusMessage = "预热完成，学校与课程术语已准备"
                }
            } catch is CancellationError {
                preparationTask.cancel()
                translationTask.cancel()
                refinementTask.cancel()
                try? await engine.finalize()
                self.isWarmingUp = false
                self.warmupTask = nil
                self.coursePreparationTask = nil
                self.translationPreparationTask = nil
                self.refinementPreparationTask = nil
                self.statusMessage = "预热已取消"
            } catch {
                preparationTask.cancel()
                translationTask.cancel()
                refinementTask.cancel()
                try? await engine.finalize()
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

    func addMarker(_ kind: MarkerKind) {
        guard let startedAt, canAddMarker else { return }
        let marker = SessionMarker(
            timestamp: max(0, Date().timeIntervalSince(startedAt)),
            kind: kind
        )
        markers.append(marker)
        currentDocument?.markers = markers
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
        snapshotTask?.cancel()
        startupTask = nil
        eventTask = nil
        captureTask = nil
        snapshotTask = nil
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
        markers = []
        startedAt = nil
        inputLevel = 0
        captureSampleRate = nil
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

    private func markFailed(_ message: String) async {
        await audioCapture?.stop()
        await postClassAudioBuffer.reset()
        let current = await stateMachine.currentState()
        if current != .idle {
            try? await stateMachine.transition(to: .failed(message: message))
        }
        lifecycleState = await stateMachine.currentState()
        inputLevel = 0
        isSummarizing = false
        statusMessage = message
    }

    private func completeSession() async {
        let current = await stateMachine.currentState()
        if isFailure(current) { return }

        var audioSaveFailureMessage: String?
        do {
            if current == .running || current == .paused {
                try await stateMachine.transition(to: .finalizing)
            }
            lifecycleState = await stateMachine.currentState()

            if let pipeline {
                await pipeline.finishPendingTranslations()
                snapshot = await pipeline.currentSnapshot()
            }

            if var document = currentDocument {
                document.endedAt = Date()
                document.segments = snapshot.finalSegments
                document.markers = markers

                if document.configuration.audioRetention == .keep,
                   !(await postClassAudioBuffer.isEmpty) {
                    statusMessage = "正在保存本地录音"
                    let audioFileName = "\(document.id.uuidString).m4a"
                    let audioURL = sessionDirectoryURL.appendingPathComponent(audioFileName)
                    do {
                        try await postClassAudioBuffer.writeM4A(to: audioURL)
                        document.audioFileName = audioFileName
                        savedAudioURL = audioURL
                    } catch {
                        audioSaveFailureMessage = error.localizedDescription
                    }
                }

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
                isSummarizing = false
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
        } catch {
            isSummarizing = false
            await markFailed(error.localizedDescription)
        }
    }

    private func cancelPreparation() async {
        await audioCapture?.stop()
        await postClassAudioBuffer.reset()
        let current = await stateMachine.currentState()
        if current == .preparing {
            try? await stateMachine.transition(to: .idle)
        }
        lifecycleState = await stateMachine.currentState()
        inputLevel = 0
        statusMessage = "已取消"
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
        try? await engine?.finalize()
    }

    private var currentWarmupSignature: RecognitionWarmupSignature {
        RecognitionWarmupSignature(
            courseName: courseName.trimmingCharacters(in: .whitespacesAndNewlines),
            recognitionTerms: parsedCourseTerms,
            profile: processingMode == .highAccuracy ? .highAccuracy : .energySaver
        )
    }

    private func prepareOfflineModel(for course: Course) async -> Bool {
        let engine = FluidAudioStreamingRecognitionEngine(profile: .unifiedOffline15s)
        do {
            try await engine.start(
                configuration: RecognitionConfiguration(course: course)
            )
            try Task.checkCancellation()
            try await engine.finalize()
            return true
        } catch {
            try? await engine.finalize()
            return false
        }
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
            await completeSession()
            return
        }

        statusMessage = "正在生成课后高精度稿"
        let offlineProfile = FluidAudioStreamingProfile.unifiedOffline15s
        let engine = FluidAudioStreamingRecognitionEngine(profile: offlineProfile)
        let collector = OfflineTranscriptCollector()
        let offlineEventTask = Task {
            for await event in engine.events {
                guard !Task.isCancelled else { return }
                await collector.consume(event)
            }
        }

        do {
            try await engine.start(configuration: configuration)
            try await postClassAudioBuffer.replay(into: engine)
            try await engine.finalize()
            await offlineEventTask.value

            if let transcript = await collector.transcript {
                let duration = await postClassAudioBuffer.duration
                _ = await pipeline.replaceFinalTranscript(
                    with: transcript,
                    duration: duration,
                    provider: offlineProfile.providerIdentifier
                )
            }
        } catch {
            offlineEventTask.cancel()
            try? await engine.finalize()
            statusMessage = "课后高精度处理失败，正在保存实时稿"
        }

        await completeSession()
    }
}

private struct RecognitionWarmupSignature: Equatable {
    var courseName: String
    var recognitionTerms: [String]
    var profile: LocalRecognitionProfile
}

private actor OfflineTranscriptCollector {
    private var finalParts: [String] = []

    var transcript: String? {
        let text = finalParts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func consume(_ event: RecognitionEvent) {
        guard case let .final(_, text, _, _, _, _) = event else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        finalParts.append(trimmedText)
    }
}
