import LingoSlateCore
@preconcurrency import AVFoundation
import Foundation

public enum SessionAudioBufferError: LocalizedError {
    case noAudio
    case inconsistentSampleRate
    case cannotCreateBuffer

    public var errorDescription: String? {
        switch self {
        case .noAudio:
            return "没有可保存的录音"
        case .inconsistentSampleRate:
            return "录音采样率不一致"
        case .cannotCreateBuffer:
            return "无法创建音频编码缓冲区"
        }
    }
}

public actor SessionAudioBuffer {
    private var frames: [AudioFrame] = []

    public init() {}

    public var isEmpty: Bool {
        frames.isEmpty
    }

    public var duration: TimeInterval {
        guard let first = frames.first, let last = frames.last else { return 0 }
        let lastFrameDuration = Double(last.samples.count) / last.sampleRate
        return max(0, last.capturedAt - first.capturedAt) + lastFrameDuration
    }

    public func append(_ frame: AudioFrame) {
        guard !frame.samples.isEmpty else { return }
        frames.append(frame)
    }

    public func replay(into engine: any SpeechRecognitionEngine) async throws {
        for frame in frames {
            try Task.checkCancellation()
            try await engine.accept(frame)
        }
    }

    public func writeM4A(to url: URL) throws {
        guard let firstFrame = frames.first else {
            throw SessionAudioBufferError.noAudio
        }
        let sampleRate = firstFrame.sampleRate
        guard sampleRate > 0,
              frames.allSatisfy({ abs($0.sampleRate - sampleRate) < 0.5 }) else {
            throw SessionAudioBufferError.inconsistentSampleRate
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).m4a"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try encodeM4A(to: temporaryURL, sampleRate: sampleRate)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private func encodeM4A(to url: URL, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        let maximumChunkSize = 65_536

        for frame in frames {
            var offset = 0
            while offset < frame.samples.count {
                let sampleCount = min(maximumChunkSize, frame.samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(sampleCount)
                ), let channel = buffer.floatChannelData?[0] else {
                    throw SessionAudioBufferError.cannotCreateBuffer
                }
                buffer.frameLength = AVAudioFrameCount(sampleCount)
                frame.samples.withUnsafeBufferPointer { samples in
                    channel.update(from: samples.baseAddress! + offset, count: sampleCount)
                }
                try file.write(from: buffer)
                offset += sampleCount
            }
        }
    }

    public func reset() {
        frames.removeAll(keepingCapacity: false)
    }
}
