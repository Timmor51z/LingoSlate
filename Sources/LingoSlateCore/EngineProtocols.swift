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
}

public struct RecognitionConfiguration: Sendable {
    public var course: Course
    public var language: String
    public var approvedTerms: [GlossaryTerm]

    public init(
        course: Course,
        language: String = "en",
        approvedTerms: [GlossaryTerm] = []
    ) {
        self.course = course
        self.language = language
        self.approvedTerms = approvedTerms.filter(\.isApproved)
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
    case failed(message: String)
    case finished
}

public protocol SpeechRecognitionEngine: Sendable {
    var events: AsyncStream<RecognitionEvent> { get }

    func start(configuration: RecognitionConfiguration) async throws
    func accept(_ frame: AudioFrame) async throws
    func finalize() async throws
}

public struct TranslationContext: Sendable {
    public var course: Course
    public var recentSourceText: [String]
    public var approvedTerms: [GlossaryTerm]

    public init(
        course: Course,
        recentSourceText: [String],
        approvedTerms: [GlossaryTerm] = []
    ) {
        self.course = course
        self.recentSourceText = recentSourceText
        self.approvedTerms = approvedTerms.filter(\.isApproved)
    }
}

public protocol TranslationEngine: Sendable {
    var identifier: String { get }

    func translate(_ text: String, context: TranslationContext) async throws -> String
}

public protocol TranslationRefinementEngine: Sendable {
    func refine(_ text: String, context: TranslationContext) async throws -> String
}

public struct StagedTranslationEngine: TranslationEngine, TranslationRefinementEngine {
    public let identifier: String

    private let primary: any TranslationEngine
    private let refinement: any TranslationEngine

    public init(
        primary: any TranslationEngine,
        refinement: any TranslationEngine
    ) {
        self.primary = primary
        self.refinement = refinement
        self.identifier = "\(primary.identifier)+\(refinement.identifier)"
    }

    public func translate(_ text: String, context: TranslationContext) async throws -> String {
        try await primary.translate(text, context: context)
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
