import Foundation

public struct AudioFrame: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var capturedAt: TimeInterval

    public init(samples: [Float], sampleRate: Double, capturedAt: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.capturedAt = capturedAt
    }

    public var normalizedLevel: Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float.zero) { partial, sample in
            partial + sample * sample
        } / Float(samples.count)
        let rms = sqrt(max(meanSquare, 0.000_000_1))
        let decibels = 20 * log10(rms)
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

public enum AudioCaptureEvent: Sendable {
    case started(sampleRate: Double)
    case frame(AudioFrame)
    case inputLevel(Float)
    case failed(message: String)
    case stopped
}

public protocol AudioCaptureEngine: Sendable {
    var events: AsyncStream<AudioCaptureEvent> { get }

    func requestPermission() async -> Bool
    func start() async throws
    func stop() async
    func captureDiagnostics() async -> AudioCaptureDiagnostics?
}

public extension AudioCaptureEngine {
    func captureDiagnostics() async -> AudioCaptureDiagnostics? { nil }
}

public protocol RecordingAudioCaptureEngine: AudioCaptureEngine {
    var recordingFrames: AsyncStream<AudioFrame> { get }
}

public struct RecognitionConfiguration: Sendable {
    public var course: Course
    public var language: String
    public var approvedTerms: [GlossaryTerm]
    public var translationTargetLanguage: String?

    public init(
        course: Course,
        language: String = "en",
        approvedTerms: [GlossaryTerm] = [],
        translationTargetLanguage: String? = nil
    ) {
        self.course = course
        self.language = language
        self.approvedTerms = approvedTerms.filter(\.isApproved)
        self.translationTargetLanguage = translationTargetLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }
}

public struct BilingualRecognitionResult: Equatable, Sendable {
    public var id: UUID
    public var sourceText: String
    public var translatedText: String?
    public var sourceLanguage: String?
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var speaker: String?
    public var recognitionProvider: String
    public var translationProvider: String

    public init(
        id: UUID,
        sourceText: String,
        translatedText: String? = nil,
        sourceLanguage: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speaker: String? = nil,
        recognitionProvider: String,
        translationProvider: String
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText?.nilIfBlank
        self.sourceLanguage = sourceLanguage?.nilIfBlank
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker?.nilIfBlank
        self.recognitionProvider = recognitionProvider
        self.translationProvider = translationProvider
    }
}

public enum RecognitionEvent: Sendable {
    case started
    case provisional(
        id: UUID,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        provider: String
    )
    case final(
        id: UUID,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speaker: String?,
        provider: String
    )
    case bilingualProvisional(BilingualRecognitionResult)
    case bilingualFinal(BilingualRecognitionResult)
    case failed(message: String)
    case finished
}

public struct TimedTranscriptChunk: Equatable, Sendable {
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
    }
}

public protocol SpeechRecognitionEngine: Sendable {
    var events: AsyncStream<RecognitionEvent> { get }

    func start(configuration: RecognitionConfiguration) async throws
    func accept(_ frame: AudioFrame) async throws
    func finalize() async throws
}

public enum TranslationPhase: Equatable, Sendable {
    case live
    case contextualLive
    case postClass
}

public struct TranslationContext: Sendable {
    public var course: Course
    public var recentSourceText: [String]
    public var approvedTerms: [GlossaryTerm]
    public var phase: TranslationPhase

    public init(
        course: Course,
        recentSourceText: [String],
        approvedTerms: [GlossaryTerm] = [],
        phase: TranslationPhase = .live
    ) {
        self.course = course
        self.recentSourceText = recentSourceText
        self.approvedTerms = approvedTerms.filter(\.isApproved)
        self.phase = phase
    }
}

public protocol TranslationEngine: Sendable {
    var identifier: String { get }

    func translate(_ text: String, context: TranslationContext) async throws -> String
}

public protocol TranslationRefinementEngine: Sendable {
    func shouldRefine(context: TranslationContext) -> Bool
    func refine(_ text: String, context: TranslationContext) async throws -> String
}

public extension TranslationRefinementEngine {
    func shouldRefine(context: TranslationContext) -> Bool { true }
}

public enum TranslationRefinementPolicy: Sendable {
    case always
    case postClassOnly
    case contextualAndPostClass
}

public struct StagedTranslationEngine: TranslationEngine, TranslationRefinementEngine {
    public let identifier: String
    public let primaryIdentifier: String
    public let refinementIdentifier: String

    private let primary: any TranslationEngine
    private let refinement: any TranslationEngine
    private let refinementPolicy: TranslationRefinementPolicy

    public init(
        primary: any TranslationEngine,
        refinement: any TranslationEngine,
        refinementPolicy: TranslationRefinementPolicy = .always
    ) {
        self.primary = primary
        self.refinement = refinement
        self.refinementPolicy = refinementPolicy
        self.primaryIdentifier = primary.identifier
        self.refinementIdentifier = refinement.identifier
        self.identifier = "\(primary.identifier)+\(refinement.identifier)"
    }

    public func translate(_ text: String, context: TranslationContext) async throws -> String {
        try await primary.translate(text, context: context)
    }

    public func shouldRefine(context: TranslationContext) -> Bool {
        switch refinementPolicy {
        case .always:
            return true
        case .postClassOnly:
            return context.phase == .postClass
        case .contextualAndPostClass:
            return context.phase != .live
        }
    }

    public func refine(_ text: String, context: TranslationContext) async throws -> String {
        try await refinement.translate(text, context: context)
    }
}

public struct SessionSummary: Codable, Hashable, Sendable {
    public var overview: [String]
    public var keyConcepts: [String]
    public var actionItems: [String]

    public init(
        overview: [String],
        keyConcepts: [String],
        actionItems: [String]
    ) {
        self.overview = overview
        self.keyConcepts = keyConcepts
        self.actionItems = actionItems
    }

    public var isEmpty: Bool {
        overview.isEmpty && keyConcepts.isEmpty && actionItems.isEmpty
    }
}

public protocol SummaryEngine: Sendable {
    func summarize(_ document: SessionDocument) async throws -> SessionSummary
}
