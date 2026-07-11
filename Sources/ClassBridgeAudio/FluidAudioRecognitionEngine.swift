@preconcurrency import AVFoundation
import ClassBridgeCore
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
    private var manager: StreamingEouAsrManager?
    private var currentSegmentID = UUID()
    private var transcriptCursor = IncrementalTranscriptCursor()
    private var segmentStartTime: TimeInterval = 0
    private var sessionStartTime: TimeInterval?
    private var latestFrameTime: TimeInterval = 0
    private var isFinalized = false

    public init() {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    public func start(configuration: RecognitionConfiguration) async throws {
        guard manager == nil else { return }

        let manager = StreamingEouAsrManager(
            chunkSize: .ms320,
            eouDebounceMs: 960
        )
        await manager.setPartialCallback { [weak self] transcript in
            Task { await self?.receivePartial(transcript) }
        }
        await manager.setEouCallback { [weak self] transcript in
            Task { await self?.receiveEndOfUtterance(transcript) }
        }
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
    }

    public func finalize() async throws {
        guard !isFinalized else { return }
        isFinalized = true

        if let manager {
            do {
                if let silenceBuffer = makeSilenceBuffer(duration: 1.5) {
                    try await manager.appendAudio(silenceBuffer)
                    try await manager.processBufferedAudio()
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
        let text = uncommittedSuffix(in: transcript)
        guard !text.isEmpty else { return }

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

    private func receiveEndOfUtterance(_ transcript: String) {
        receiveFinalTranscript(transcript)
    }

    private func receiveFinalTranscript(_ transcript: String) {
        let text = uncommittedSuffix(in: transcript)
        guard !text.isEmpty else { return }

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
        segmentStartTime = latestFrameTime
        currentSegmentID = UUID()
    }

    private func uncommittedSuffix(in transcript: String) -> String {
        transcriptCursor.uncommittedText(in: transcript)
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
