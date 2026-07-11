@preconcurrency import AVFoundation
import ClassBridgeCore
import FluidAudio
import Foundation

public enum FluidAudioStreamingProfile: String, CaseIterable, Sendable {
    case unified640ms
    case unified1120ms
    case unifiedOffline15s
    case nemotron1120ms

    public var displayName: String {
        switch self {
        case .unified640ms:
            return "Parakeet Unified 0.6B, 640 ms"
        case .unified1120ms:
            return "Parakeet Unified 0.6B, 1120 ms"
        case .unifiedOffline15s:
            return "Parakeet Unified 0.6B, offline 15 s"
        case .nemotron1120ms:
            return "Nemotron 0.6B, 1120 ms"
        }
    }

    fileprivate var variant: StreamingModelVariant {
        switch self {
        case .unified640ms:
            return .parakeetUnified640ms
        case .unified1120ms:
            return .parakeetUnified1120ms
        case .unifiedOffline15s:
            return .parakeetUnifiedOffline15s
        case .nemotron1120ms:
            return .nemotron1120ms
        }
    }

    public var providerIdentifier: String {
        "fluidaudio-\(rawValue)"
    }

    fileprivate var emitsStreamingPartials: Bool {
        self != .unifiedOffline15s
    }
}

public enum LocalRecognitionProfile: String, CaseIterable, Sendable {
    case energySaver
    case highAccuracy
}

public enum LocalRecognitionEngineFactory {
    public static func make(
        profile: LocalRecognitionProfile,
        enhancesAudio: Bool? = nil
    ) -> any SpeechRecognitionEngine {
        let base: any SpeechRecognitionEngine
        switch profile {
        case .energySaver:
            base = FluidAudioRecognitionEngine()
        case .highAccuracy:
            base = FluidAudioStreamingRecognitionEngine(profile: .unified1120ms)
        }

        let shouldEnhanceAudio = enhancesAudio ?? (profile == .energySaver)
        guard shouldEnhanceAudio else { return base }
        return AudioEnhancingRecognitionEngine(base: base)
    }
}

public actor FluidAudioStreamingRecognitionEngine: SpeechRecognitionEngine {
    public nonisolated let events: AsyncStream<RecognitionEvent>

    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private let profile: FluidAudioStreamingProfile
    private let maximumSegmentDuration: TimeInterval
    private var manager: (any StreamingAsrManager)?
    private var currentSegmentID = UUID()
    private var transcriptCursor = IncrementalTranscriptCursor()
    private var lastProvisionalText = ""
    private var segmentStartTime: TimeInterval = 0
    private var sessionStartTime: TimeInterval?
    private var latestFrameTime: TimeInterval = 0
    private var isFinalized = false

    public init(
        profile: FluidAudioStreamingProfile = .unified640ms,
        maximumSegmentDuration: TimeInterval = 15
    ) {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.profile = profile
        self.maximumSegmentDuration = max(5, maximumSegmentDuration)
    }

    public func start(configuration: RecognitionConfiguration) async throws {
        guard manager == nil else { return }

        let manager = profile.variant.createManager()
        do {
            try await manager.loadModels()
            try Task.checkCancellation()
        } catch {
            await manager.cleanup()
            throw error
        }

        self.manager = manager
        continuation.yield(.started)
    }

    public func accept(_ frame: AudioFrame) async throws {
        guard let manager else {
            throw FluidAudioRecognitionError.notStarted
        }
        guard !frame.samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: frame.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frame.samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            throw FluidAudioRecognitionError.invalidFrame
        }

        buffer.frameLength = AVAudioFrameCount(frame.samples.count)
        frame.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }

        if sessionStartTime == nil {
            sessionStartTime = frame.capturedAt
        }
        latestFrameTime = max(0, frame.capturedAt - (sessionStartTime ?? frame.capturedAt))

        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
        guard profile.emitsStreamingPartials else { return }
        let transcript = await manager.getPartialTranscript()
        emitAvailableTranscript(transcript)
    }

    public func finalize() async throws {
        guard !isFinalized else { return }
        isFinalized = true

        if let manager {
            do {
                let transcript = try await manager.finish()
                receiveFinalTranscript(transcript)
                await manager.cleanup()
            } catch {
                await manager.cleanup()
                continuation.yield(.failed(message: error.localizedDescription))
                continuation.finish()
                throw error
            }
        }
        continuation.yield(.finished)
        continuation.finish()
    }

    private func emitAvailableTranscript(_ transcript: String) {
        let reachedMaximumDuration = latestFrameTime - segmentStartTime >= maximumSegmentDuration
        if reachedMaximumDuration {
            if !receiveFinalTranscript(transcript) {
                advanceSegmentBoundary()
            }
        } else {
            receivePartial(transcript)
        }
    }

    private func receivePartial(_ transcript: String) {
        let text = transcriptCursor.uncommittedText(in: transcript)
        guard !text.isEmpty, text != lastProvisionalText else { return }
        lastProvisionalText = text
        continuation.yield(
            .provisional(
                id: currentSegmentID,
                text: text,
                startTime: segmentStartTime,
                endTime: latestFrameTime,
                provider: profile.providerIdentifier
            )
        )
    }

    @discardableResult
    private func receiveFinalTranscript(_ transcript: String) -> Bool {
        let text = transcriptCursor.uncommittedText(in: transcript)
        guard !text.isEmpty else { return false }

        continuation.yield(
            .final(
                id: currentSegmentID,
                text: text,
                startTime: segmentStartTime,
                endTime: latestFrameTime,
                speaker: nil,
                provider: profile.providerIdentifier
            )
        )
        transcriptCursor.commit(transcript)
        advanceSegmentBoundary()
        return true
    }

    private func advanceSegmentBoundary() {
        lastProvisionalText = ""
        segmentStartTime = latestFrameTime
        currentSegmentID = UUID()
    }
}
