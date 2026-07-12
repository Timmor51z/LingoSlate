@preconcurrency import AVFoundation
import LingoSlateCore
import FluidAudio
import Foundation

enum FluidAudioRecognitionError: LocalizedError, Sendable {
    case notStarted
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .notStarted:
            return "本地语音模型尚未就绪"
        case .invalidFrame:
            return "识别器收到了无效的音频帧"
        }
    }
}

public actor FluidAudioRecognitionEngine: SpeechRecognitionEngine {
    public nonisolated let events: AsyncStream<RecognitionEvent>

    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private let maximumSegmentDuration: TimeInterval
    private var manager: StreamingEouAsrManager?
    private var currentSegmentID = UUID()
    private var transcriptCursor = IncrementalTranscriptCursor()
    private var lastProvisionalText = ""
    private var segmentStartTime: TimeInterval = 0
    private var sessionStartTime: TimeInterval?
    private var latestFrameTime: TimeInterval = 0
    private var isFinalized = false

    public init(maximumSegmentDuration: TimeInterval = 15) {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.maximumSegmentDuration = max(5, maximumSegmentDuration)
    }

    public func start(configuration: RecognitionConfiguration) async throws {
        guard manager == nil else { return }

        let manager = StreamingEouAsrManager(
            chunkSize: .ms320,
            eouDebounceMs: 960
        )
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
        await emitAvailableTranscript(from: manager)
    }

    public func finalize() async throws {
        guard !isFinalized else { return }
        isFinalized = true

        if let manager {
            do {
                if let silenceBuffer = makeSilenceBuffer(duration: 1.5) {
                    try await manager.appendAudio(silenceBuffer)
                    try await manager.processBufferedAudio()
                    await emitAvailableTranscript(from: manager)
                }
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
                provider: "fluidaudio-parakeet-eou"
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
                provider: "fluidaudio-parakeet-eou"
            )
        )

        transcriptCursor.commit(transcript)
        advanceSegmentBoundary()
        return true
    }

    private func emitAvailableTranscript(
        from manager: StreamingEouAsrManager
    ) async {
        let transcript = await manager.getPartialTranscript()
        let reachedMaximumDuration = latestFrameTime - segmentStartTime >= maximumSegmentDuration

        if await manager.eouDetected {
            if !receiveFinalTranscript(transcript) {
                advanceSegmentBoundary()
            }
            await manager.reset()
            transcriptCursor = IncrementalTranscriptCursor()
        } else if reachedMaximumDuration {
            if !receiveFinalTranscript(transcript) {
                advanceSegmentBoundary()
            }
        } else {
            receivePartial(transcript)
        }
    }

    private func advanceSegmentBoundary() {
        lastProvisionalText = ""
        segmentStartTime = latestFrameTime
        currentSegmentID = UUID()
    }

    private func makeSilenceBuffer(duration: TimeInterval) -> AVAudioPCMBuffer? {
        let sampleRate = 16_000.0
        let sampleCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: sampleCount
        ), let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        channel.initialize(repeating: 0, count: Int(sampleCount))
        buffer.frameLength = sampleCount
        return buffer
    }
}
