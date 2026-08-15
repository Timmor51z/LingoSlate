import Combine
import Foundation
import LingoSlateCore
import LingoSlateSoniox

public enum MobileSessionState: Equatable, Sendable {
    case idle
    case preparing
    case listening
    case finishing
    case complete
    case failed(String)
}

@MainActor
public final class MobileSessionController: ObservableObject {
    public typealias APIKeyProvider = @Sendable () async throws -> String
    public typealias CaptureFactory = @Sendable (URL) -> any AudioCaptureEngine
    public typealias RecognitionFactory = @Sendable (String) -> any SpeechRecognitionEngine

    @Published public private(set) var state: MobileSessionState = .idle
    @Published public private(set) var snapshot = TranscriptSnapshot()
    @Published public private(set) var markers: [SessionMarker] = []
    @Published public private(set) var inputLevel: Float = 0
    @Published public private(set) var statusMessage = "准备就绪"
    public let sessionDirectoryURL: URL

    private let apiKeyProvider: APIKeyProvider
    private let captureFactory: CaptureFactory
    private let recognitionFactory: RecognitionFactory
    private let sessionStore: SessionStore

    private var capture: (any AudioCaptureEngine)?
    private var recognition: (any SpeechRecognitionEngine)?
    private var currentDocument: SessionDocument?
    private var eventTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var lastCheckpointedFinalCount = 0
    private var lastCheckpointedTranslationCount = 0

    public init(
        apiKeyProvider: @escaping APIKeyProvider,
        sessionDirectoryURL: URL,
        captureFactory: @escaping CaptureFactory,
        recognitionFactory: @escaping RecognitionFactory = {
            SonioxRecognitionEngine(apiKey: $0)
        }
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.sessionDirectoryURL = sessionDirectoryURL
        self.sessionStore = SessionStore(directoryURL: sessionDirectoryURL)
        self.captureFactory = captureFactory
        self.recognitionFactory = recognitionFactory
    }

    #if os(iOS)
    public convenience init(apiKeyProvider: @escaping APIKeyProvider) {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("LingoSlate", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        self.init(
            apiKeyProvider: apiKeyProvider,
            sessionDirectoryURL: directory,
            captureFactory: { IOSMicrophoneCapture(recordingURL: $0) }
        )
    }
    #endif

    public var canStart: Bool {
        switch state {
        case .idle, .complete, .failed:
            return true
        case .preparing, .listening, .finishing:
            return false
        }
    }

    public func start(courseName: String = "", recognitionTerms: [String] = []) async {
        await start(
            course: Course(name: courseName, recognitionTerms: recognitionTerms),
            profile: UserProfile()
        )
    }

    public func start(course: Course, profile: UserProfile = UserProfile()) async {
        guard canStart else { return }
        cancelTasks()
        sessionID = UUID()
        let startingSessionID = sessionID
        snapshot = TranscriptSnapshot()
        markers = []
        inputLevel = 0
        currentDocument = nil
        lastCheckpointedFinalCount = 0
        lastCheckpointedTranslationCount = 0
        state = .preparing
        statusMessage = "正在连接 Soniox"

        do {
            let key = try await apiKeyProvider()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try ensureSessionIsCurrent(startingSessionID)
            guard !key.isEmpty else { throw SonioxRecognitionError.missingAPIKey }

            let approvedTerms = RegionalAcademicGlossary.approvedTerms(for: profile)
                + CourseTranslationGlossary.approvedTerms(for: course)
            let pipeline = SubtitlePipeline(
                course: course,
                translationEngine: CloudTranslationOnlyEngine(),
                approvedTerms: approvedTerms
            )
            let document = SessionDocument(
                id: startingSessionID,
                configuration: SessionConfiguration(
                    course: course,
                    processingMode: .soniox,
                    audioRetention: .keep
                ),
                audioFileName: "\(startingSessionID.uuidString).m4a"
            )
            let audioURL = sessionDirectoryURL.appendingPathComponent(
                document.audioFileName!
            )
            let capture = captureFactory(audioURL)
            let recognition = recognitionFactory(key)
            self.capture = capture
            self.recognition = recognition

            guard await capture.requestPermission() else {
                throw MobileSessionError.microphonePermissionDenied
            }
            try ensureSessionIsCurrent(startingSessionID)
            currentDocument = document
            try await sessionStore.save(document)
            observe(pipeline: pipeline, recognition: recognition, capture: capture)
            try await recognition.start(
                configuration: RecognitionConfiguration(
                    course: course,
                    approvedTerms: approvedTerms,
                    translationTargetLanguage: "zh"
                )
            )
            try ensureSessionIsCurrent(startingSessionID)
            try await capture.start()
        } catch is CancellationError {
            await capture?.stop()
            await discardCurrentDocument()
            state = .idle
            statusMessage = "已取消"
        } catch {
            await fail(error.localizedDescription)
        }
    }

    public func stop() async {
        guard state == .listening || state == .preparing else { return }
        let wasPreparing = state == .preparing
        sessionID = UUID()
        state = .finishing
        statusMessage = "正在整理字幕"
        await capture?.stop()
        if wasPreparing {
            await discardCurrentDocument()
            state = .idle
            statusMessage = "已取消"
            return
        }
        do {
            try await recognition?.finalize()
        } catch {
            await fail(error.localizedDescription)
        }
    }

    public func addMarker(_ kind: MarkerKind = .bookmark) {
        guard state == .listening else { return }
        let timestamp = snapshot.provisionalSegment?.endTime
            ?? snapshot.finalSegments.last?.endTime
            ?? 0
        markers.append(SessionMarker(timestamp: timestamp, kind: kind))
        currentDocument?.markers = markers
        scheduleCheckpoint()
    }

    private func observe(
        pipeline: SubtitlePipeline,
        recognition: any SpeechRecognitionEngine,
        capture: any AudioCaptureEngine
    ) {
        snapshotTask = Task { [weak self] in
            for await value in await pipeline.snapshots() {
                guard !Task.isCancelled else { return }
                self?.receiveSnapshot(value)
            }
        }
        eventTask = Task { [weak self] in
            for await event in recognition.events {
                guard !Task.isCancelled else { return }
                await pipeline.consume(event)
                switch event {
                case .started:
                    self?.state = .listening
                    self?.statusMessage = "正在听课"
                case let .failed(message):
                    await self?.fail(message)
                case .finished:
                    await self?.completeSession()
                default:
                    break
                }
            }
        }
        captureTask = Task.detached(priority: .userInitiated) { [weak self] in
            var inputLevelTask: Task<Void, Never>?
            defer { inputLevelTask?.cancel() }
            for await event in capture.events {
                guard !Task.isCancelled else { return }
                switch event {
                case let .frame(frame):
                    do {
                        try await recognition.accept(frame)
                    } catch {
                        await self?.fail(error.localizedDescription)
                        return
                    }
                case let .inputLevel(level):
                    inputLevelTask?.cancel()
                    inputLevelTask = Task { @MainActor [weak self] in
                        guard !Task.isCancelled else { return }
                        self?.inputLevel = level
                    }
                case let .failed(message):
                    await self?.fail(message)
                    return
                case .started, .stopped:
                    break
                }
            }
        }
    }

    private func fail(_ message: String) async {
        guard case .failed = state else {
            state = .failed(message)
            statusMessage = message
            inputLevel = 0
            await capture?.stop()
            currentDocument?.endedAt = Date()
            currentDocument?.segments = snapshot.finalSegments
            currentDocument?.markers = markers
            currentDocument?.failureMessage = message
            if let document = currentDocument {
                try? await sessionStore.save(document)
            }
            return
        }
    }

    private func receiveSnapshot(_ value: TranscriptSnapshot) {
        snapshot = value
        currentDocument?.segments = value.finalSegments
        let translatedCount = value.finalSegments.filter { $0.translatedText != nil }.count
        guard value.finalSegments.count != lastCheckpointedFinalCount
                || translatedCount != lastCheckpointedTranslationCount else { return }
        lastCheckpointedFinalCount = value.finalSegments.count
        lastCheckpointedTranslationCount = translatedCount
        scheduleCheckpoint()
    }

    private func scheduleCheckpoint() {
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let document = self?.currentDocument else { return }
            try? await self?.sessionStore.save(document)
        }
    }

    private func completeSession() async {
        checkpointTask?.cancel()
        currentDocument?.endedAt = Date()
        currentDocument?.segments = snapshot.finalSegments
        currentDocument?.markers = markers
        currentDocument?.audioCaptureDiagnostics = await capture?.captureDiagnostics()
        guard var document = currentDocument else {
            state = .failed("课堂记录保存失败")
            return
        }
        do {
            document.summary = DeterministicSummaryEngine.makeSummary(for: document)
            document.processedAt = Date()
            document.isPostProcessingComplete = true
            currentDocument = document
            try await sessionStore.save(document)
            state = .complete
            statusMessage = "课堂已保存"
            inputLevel = 0
        } catch {
            state = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    private func discardCurrentDocument() async {
        checkpointTask?.cancel()
        guard let document = currentDocument else { return }
        try? await sessionStore.delete(id: document.id)
        currentDocument = nil
    }

    private func cancelTasks() {
        eventTask?.cancel()
        captureTask?.cancel()
        snapshotTask?.cancel()
        checkpointTask?.cancel()
        eventTask = nil
        captureTask = nil
        snapshotTask = nil
        checkpointTask = nil
        capture = nil
        recognition = nil
    }

    private func ensureSessionIsCurrent(_ expectedID: UUID) throws {
        guard sessionID == expectedID, state != .finishing else {
            throw CancellationError()
        }
    }
}

private enum MobileSessionError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        "请在系统设置中允许 LingoSlate 使用麦克风"
    }
}

private struct CloudTranslationOnlyEngine: TranslationEngine {
    let identifier = "soniox-cloud-only"

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        throw SonioxRecognitionError.server("该片段未返回云端译文")
    }
}
