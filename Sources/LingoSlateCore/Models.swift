import Foundation

public struct Course: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var code: String?
    public var roughDescription: String?
    public var domain: String?
    public var lecturerNames: [String]
    public var lecturerAccent: LecturerAccentProfile?
    public var recognitionTerms: [String]?
    public var targetLanguage: String
    public var contextMaturity: Int

    public init(
        id: UUID = UUID(),
        name: String,
        code: String? = nil,
        roughDescription: String? = nil,
        domain: String? = nil,
        lecturerNames: [String] = [],
        lecturerAccent: LecturerAccentProfile? = nil,
        recognitionTerms: [String] = [],
        targetLanguage: String = "zh-Hans",
        contextMaturity: Int = 0
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.code = code?.nilIfBlank
        self.roughDescription = roughDescription?.nilIfBlank
        self.domain = domain?.nilIfBlank
        self.lecturerNames = lecturerNames
        self.lecturerAccent = lecturerAccent
        let recognitionTerms = recognitionTerms.compactMap(\.nilIfBlank)
        self.recognitionTerms = recognitionTerms.isEmpty ? nil : recognitionTerms
        self.targetLanguage = targetLanguage
        self.contextMaturity = max(0, contextMaturity)
    }

}

public enum LecturerAccentProfile: String, Codable, CaseIterable, Sendable {
    case indianEnglish

    public var displayName: String {
        switch self {
        case .indianEnglish:
            return "Indian English"
        }
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
    case soniox
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

public struct SessionPreparationDiagnostics: Codable, Hashable, Sendable {
    public var preparedAt: Date
    public var asrModelReady: Bool
    public var quickTranslationReady: Bool
    public var enhancedTranslationReady: Bool
    public var usedFoundationModel: Bool
    public var generatedTermCount: Int
    public var terms: [String]
    public var prewarmedRecognitionReused: Bool?

    public init(
        preparedAt: Date = Date(),
        asrModelReady: Bool,
        quickTranslationReady: Bool,
        enhancedTranslationReady: Bool,
        usedFoundationModel: Bool,
        generatedTermCount: Int,
        terms: [String],
        prewarmedRecognitionReused: Bool? = nil
    ) {
        self.preparedAt = preparedAt
        self.asrModelReady = asrModelReady
        self.quickTranslationReady = quickTranslationReady
        self.enhancedTranslationReady = enhancedTranslationReady
        self.usedFoundationModel = usedFoundationModel
        self.generatedTermCount = max(0, generatedTermCount)
        self.terms = terms
        self.prewarmedRecognitionReused = prewarmedRecognitionReused
    }
}

public struct AudioCaptureDiagnostics: Codable, Hashable, Sendable {
    public var inputDeviceName: String?
    public var inputDeviceUID: String?
    public var inputSampleRate: Double?
    public var recognitionDroppedFrameCount: Int
    public var recordingDroppedFrameCount: Int
    public var routeChangeCount: Int

    public init(
        inputDeviceName: String? = nil,
        inputDeviceUID: String? = nil,
        inputSampleRate: Double? = nil,
        recognitionDroppedFrameCount: Int = 0,
        recordingDroppedFrameCount: Int = 0,
        routeChangeCount: Int = 0
    ) {
        self.inputDeviceName = inputDeviceName?.nilIfBlank
        self.inputDeviceUID = inputDeviceUID?.nilIfBlank
        self.inputSampleRate = inputSampleRate
        self.recognitionDroppedFrameCount = max(0, recognitionDroppedFrameCount)
        self.recordingDroppedFrameCount = max(0, recordingDroppedFrameCount)
        self.routeChangeCount = max(0, routeChangeCount)
    }
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
    public var translationProvider: String?
    public var translationFailureReason: String?
    public var translationExclusionReason: String?
    public var sourceLanguage: String?

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        sourceText: String,
        translatedText: String? = nil,
        speaker: String? = nil,
        state: TranscriptSegmentState,
        provider: String,
        isUserCorrected: Bool = false,
        translationProvider: String? = nil,
        translationFailureReason: String? = nil,
        translationExclusionReason: String? = nil,
        sourceLanguage: String? = nil
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
        self.translationProvider = translationProvider
        self.translationFailureReason = translationFailureReason
        self.translationExclusionReason = translationExclusionReason
        self.sourceLanguage = sourceLanguage?.nilIfBlank
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
    public var schemaVersion: Int?
    public let id: UUID
    public var configuration: SessionConfiguration
    public var startedAt: Date
    public var endedAt: Date?
    public var processedAt: Date?
    public var segments: [TranscriptSegment]
    public var markers: [SessionMarker]
    public var summary: SessionSummary?
    public var audioFileName: String?
    public var preparationDiagnostics: SessionPreparationDiagnostics?
    public var audioCaptureDiagnostics: AudioCaptureDiagnostics?
    public var failureMessage: String?
    public var isPostProcessingComplete: Bool?

    public init(
        schemaVersion: Int? = 1,
        id: UUID = UUID(),
        configuration: SessionConfiguration,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        processedAt: Date? = nil,
        segments: [TranscriptSegment] = [],
        markers: [SessionMarker] = [],
        summary: SessionSummary? = nil,
        audioFileName: String? = nil,
        preparationDiagnostics: SessionPreparationDiagnostics? = nil,
        audioCaptureDiagnostics: AudioCaptureDiagnostics? = nil,
        failureMessage: String? = nil,
        isPostProcessingComplete: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.configuration = configuration
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.processedAt = processedAt
        self.segments = segments
        self.markers = markers
        self.summary = summary
        self.audioFileName = audioFileName?.nilIfBlank
        self.preparationDiagnostics = preparationDiagnostics
        self.audioCaptureDiagnostics = audioCaptureDiagnostics
        self.failureMessage = failureMessage?.nilIfBlank
        self.isPostProcessingComplete = isPostProcessingComplete
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

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
