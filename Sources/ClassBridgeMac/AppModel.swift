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

    private let stateMachine = SessionStateMachine()
    private let sessionStore: SessionStore

    private var pipeline: SubtitlePipeline?
    private var recognitionEngine: (any SpeechRecognitionEngine)?
    private var currentDocument: SessionDocument?
    private var eventTask: Task<Void, Never>?
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
        Course(name: courseName).isReadyToStart && lifecycleState == .idle
    }

    var isActive: Bool {
        switch lifecycleState {
        case .preparing, .running, .paused, .finalizing:
            return true
        default:
            return false
        }
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
        let engine = DemoRecognitionEngine()

        self.pipeline = pipeline
        recognitionEngine = engine
        currentDocument = SessionDocument(configuration: configuration)
        markers = []
        snapshot = TranscriptSnapshot()
        startedAt = Date()
        statusMessage = "正在准备"

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
                    await self?.markRunning()
                case let .failed(message):
                    await self?.markFailed(message)
                case .finished:
                    await self?.completeSession()
                default:
                    break
                }
            }
        }

        Task {
            do {
                try await stateMachine.transition(to: .preparing)
                lifecycleState = await stateMachine.currentState()
                try await engine.start(configuration: RecognitionConfiguration(course: course))
            } catch {
                await markFailed(error.localizedDescription)
            }
        }
    }

    func stopSession() {
        guard isActive, let recognitionEngine else { return }
        statusMessage = "正在整理字幕"

        Task {
            do {
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
        guard let startedAt, isActive else { return }
        let marker = SessionMarker(
            timestamp: max(0, Date().timeIntervalSince(startedAt)),
            kind: kind
        )
        markers.append(marker)
        currentDocument?.markers = markers
    }

    func resetForNextSession() {
        guard !isActive else { return }
        eventTask?.cancel()
        snapshotTask?.cancel()
        eventTask = nil
        snapshotTask = nil
        pipeline = nil
        recognitionEngine = nil
        currentDocument = nil
        snapshot = TranscriptSnapshot()
        markers = []
        startedAt = nil
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
            statusMessage = "字幕链路预览中"
        } catch {
            await markFailed(error.localizedDescription)
        }
    }

    private func markFailed(_ message: String) async {
        let current = await stateMachine.currentState()
        if current != .idle {
            try? await stateMachine.transition(to: .failed(message: message))
        }
        lifecycleState = await stateMachine.currentState()
        statusMessage = message
    }

    private func completeSession() async {
        let current = await stateMachine.currentState()

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

    private func isFailure(_ state: SessionLifecycleState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
