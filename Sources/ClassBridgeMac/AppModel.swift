import ClassBridgeAudio
import ClassBridgeCore
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var courseName = "Mobile Computing and Software Architecture"
    @Published var sessionKind: SessionKind = .lecture
    @Published var processingMode: ProcessingMode = .local
    @Published var audioSource: AudioSource = .microphone
    @Published private(set) var lifecycleState: SessionLifecycleState = .idle
    @Published private(set) var snapshot = TranscriptSnapshot()
    @Published private(set) var markers: [SessionMarker] = []
    @Published private(set) var statusMessage = "就绪"
    @Published private(set) var startedAt: Date?
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var captureSampleRate: Double?

    private let stateMachine = SessionStateMachine()
    private let sessionStore: SessionStore

    private var pipeline: SubtitlePipeline?
    private var recognitionEngine: (any SpeechRecognitionEngine)?
    private var audioCapture: (any AudioCaptureEngine)?
    private var currentDocument: SessionDocument?
    private var startupTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let sessionDirectory = applicationSupport
            .appendingPathComponent("ClassBridge", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        sessionStore = SessionStore(directoryURL: sessionDirectory)
    }

    var canStart: Bool {
        Course(name: courseName).isReadyToStart
            && lifecycleState == .idle
            && processingMode == .local
            && audioSource == .microphone
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

        let course = Course(name: courseName)
        let configuration = SessionConfiguration(
            course: course,
            kind: sessionKind,
            processingMode: processingMode,
            audioSource: audioSource,
            audioRetention: .discard
        )
        let pipeline = SubtitlePipeline(
            course: course,
            translationEngine: DemoTranslationEngine()
        )
        let engine = FluidAudioRecognitionEngine()
        let capture = MicrophoneAudioCapture()

        self.pipeline = pipeline
        recognitionEngine = engine
        audioCapture = capture
        currentDocument = SessionDocument(configuration: configuration)
        markers = []
        snapshot = TranscriptSnapshot()
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
                    await self?.completeSession()
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
                try await self.stateMachine.transition(to: .preparing)
                self.lifecycleState = await self.stateMachine.currentState()

                guard await capture.requestPermission() else {
                    throw MicrophoneCaptureError.permissionDenied
                }
                self.statusMessage = "正在加载本地语音模型（首次约 120 MB）"
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

    func addMarker(_ kind: MarkerKind) {
        guard let startedAt, canAddMarker else { return }
        let marker = SessionMarker(
            timestamp: max(0, Date().timeIntervalSince(startedAt)),
            kind: kind
        )
        markers.append(marker)
        currentDocument?.markers = markers
    }

    func resetForNextSession() {
        guard !isActive else { return }
        startupTask?.cancel()
        eventTask?.cancel()
        captureTask?.cancel()
        snapshotTask?.cancel()
        startupTask = nil
        eventTask = nil
        captureTask = nil
        snapshotTask = nil
        pipeline = nil
        recognitionEngine = nil
        audioCapture = nil
        currentDocument = nil
        snapshot = TranscriptSnapshot()
        markers = []
        startedAt = nil
        inputLevel = 0
        captureSampleRate = nil
        statusMessage = "就绪"

        Task {
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
        let current = await stateMachine.currentState()
        if current != .idle {
            try? await stateMachine.transition(to: .failed(message: message))
        }
        lifecycleState = await stateMachine.currentState()
        inputLevel = 0
        statusMessage = message
    }

    private func completeSession() async {
        let current = await stateMachine.currentState()
        if isFailure(current) { return }

        do {
            if current == .running || current == .paused {
                try await stateMachine.transition(to: .finalizing)
            }
            if await stateMachine.currentState() == .finalizing {
                try await stateMachine.transition(to: .completed)
            }
            lifecycleState = await stateMachine.currentState()

            if var document = currentDocument {
                document.endedAt = Date()
                document.segments = snapshot.finalSegments
                document.markers = markers
                try await sessionStore.save(document)
                currentDocument = document
                statusMessage = "已保存"
            } else {
                statusMessage = "已完成"
            }
        } catch {
            await markFailed(error.localizedDescription)
        }
    }

    private func cancelPreparation() async {
        await audioCapture?.stop()
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
}
