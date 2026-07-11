import Foundation

public struct Course: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var code: String?
    public var roughDescription: String?
    public var domain: String?
    public var lecturerNames: [String]
    public var targetLanguage: String
    public var contextMaturity: Int

    public init(
        id: UUID = UUID(),
        name: String,
        code: String? = nil,
        roughDescription: String? = nil,
        domain: String? = nil,
        lecturerNames: [String] = [],
        targetLanguage: String = "zh-Hans",
        contextMaturity: Int = 0
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.code = code?.nilIfBlank
        self.roughDescription = roughDescription?.nilIfBlank
        self.domain = domain?.nilIfBlank
        self.lecturerNames = lecturerNames
        self.targetLanguage = targetLanguage
        self.contextMaturity = max(0, contextMaturity)
    }

    public var isReadyToStart: Bool {
        !name.isEmpty
    }
}
public struct GlossaryTerm: Codable, Hashable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case user
        case officialCourseSource
        case importedDocument
        case sessionSuggestion
    }

    public let id: UUID
    public var source: String
    public var target: String
    public var aliases: [String]
    public var origin: Origin
    public var confidence: Double
    public var isApproved: Bool

    public init(
        id: UUID = UUID(),
        source: String,
        target: String,
        aliases: [String] = [],
        origin: Origin,
        confidence: Double = 1,
        isApproved: Bool = false
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.aliases = aliases
        self.origin = origin
        self.confidence = min(max(confidence, 0), 1)
        self.isApproved = isApproved
    }
}

public enum SessionKind: String, Codable, CaseIterable, Sendable {
    case lecture
    case meeting
}

public enum ProcessingMode: String, Codable, CaseIterable, Sendable {
    case local
    case highAccuracy
}

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone
    case systemAudio
    case mixed
}

public enum AudioRetentionPolicy: String, Codable, CaseIterable, Sendable {
    case discard
    case untilSummary
    case keep
}

public struct SessionConfiguration: Codable, Hashable, Sendable {
    public var course: Course
    public var kind: SessionKind
    public var processingMode: ProcessingMode
    public var audioSource: AudioSource
    public var audioRetention: AudioRetentionPolicy

    public init(
        course: Course,
        kind: SessionKind = .lecture,
        processingMode: ProcessingMode = .local,
        audioSource: AudioSource = .microphone,
        audioRetention: AudioRetentionPolicy = .discard
    ) {
        self.course = course
        self.kind = kind
        self.processingMode = processingMode
        self.audioSource = audioSource
        self.audioRetention = audioRetention
    }
}

public enum TranscriptSegmentState: String, Codable, Sendable {
    case provisional
    case final
    case translated
}

public struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var sourceText: String
    public var translatedText: String?
    public var speaker: String?
    public var state: TranscriptSegmentState
    public var provider: String
    public var isUserCorrected: Bool

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        sourceText: String,
        translatedText: String? = nil,
        speaker: String? = nil,
        state: TranscriptSegmentState,
        provider: String,
        isUserCorrected: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.speaker = speaker
        self.state = state
        self.provider = provider
        self.isUserCorrected = isUserCorrected
    }
}

public enum MarkerKind: String, Codable, CaseIterable, Sendable {
    case bookmark
    case important
    case question
    case actionItem
}

public struct SessionMarker: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var timestamp: TimeInterval
    public var kind: MarkerKind
    public var note: String?

    public init(
        id: UUID = UUID(),
        timestamp: TimeInterval,
        kind: MarkerKind,
        note: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.note = note?.nilIfBlank
    }
}

public struct SessionDocument: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var configuration: SessionConfiguration
    public var startedAt: Date
    public var endedAt: Date?
    public var segments: [TranscriptSegment]
    public var markers: [SessionMarker]

    public init(
        id: UUID = UUID(),
        configuration: SessionConfiguration,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        segments: [TranscriptSegment] = [],
        markers: [SessionMarker] = []
    ) {
        self.id = id
        self.configuration = configuration
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
        self.markers = markers
    }
}

public struct TranscriptSnapshot: Equatable, Sendable {
    public var finalSegments: [TranscriptSegment]
    public var provisionalSegment: TranscriptSegment?

    public init(
        finalSegments: [TranscriptSegment] = [],
        provisionalSegment: TranscriptSegment? = nil
    ) {
        self.finalSegments = finalSegments
        self.provisionalSegment = provisionalSegment
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
