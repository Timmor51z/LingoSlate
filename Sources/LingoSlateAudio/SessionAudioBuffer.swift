import LingoSlateCore
@preconcurrency import AVFoundation
import Foundation

public enum SessionAudioBufferError: LocalizedError {
    case noAudio
    case notPrepared
    case inconsistentSampleRate
    case cannotCreateBuffer

    public var errorDescription: String? {
        switch self {
        case .noAudio:
            return "没有可保存的录音"
        case .notPrepared:
            return "录音文件尚未准备好"
        case .inconsistentSampleRate:
            return "录音采样率不一致"
        case .cannotCreateBuffer:
            return "无法创建音频编码缓冲区"
        }
    }
}

public actor SessionAudioBuffer {
    private static let writeChunkSize = 8_192
    private static let replayChunkSize = 16_000

    private var audioFile: AVAudioFile?
    private var temporaryURL: URL?
    private var destinationURL: URL?
    private var savedURL: URL?
    private var sampleRate: Double?
    private var sampleCount: Int64 = 0
    private var pendingSamples: [Float] = []

    public init() {}

    public var isEmpty: Bool {
        sampleCount == 0
    }

    public var duration: TimeInterval {
        guard let sampleRate, sampleRate > 0 else { return 0 }
        return Double(sampleCount) / sampleRate
    }

    public func prepareRecording(to url: URL) throws {
        clearState(removingTemporaryFile: true)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        destinationURL = url
        temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).m4a"
        )
        pendingSamples.reserveCapacity(Self.writeChunkSize * 2)
    }

    public func append(_ frame: AudioFrame) throws {
        guard destinationURL != nil, temporaryURL != nil else {
            throw SessionAudioBufferError.notPrepared
        }
        guard !frame.samples.isEmpty else { return }
        guard frame.sampleRate > 0 else {
            throw SessionAudioBufferError.inconsistentSampleRate
        }

        if let sampleRate {
            guard abs(frame.sampleRate - sampleRate) < 0.5 else {
                throw SessionAudioBufferError.inconsistentSampleRate
            }
        } else {
            sampleRate = frame.sampleRate
            try openAudioFile(sampleRate: frame.sampleRate)
        }

        pendingSamples.append(contentsOf: frame.samples)
        sampleCount += Int64(frame.samples.count)
        if pendingSamples.count >= Self.writeChunkSize {
            try flushPendingSamples()
        }
    }

    @discardableResult
    public func finishWriting() throws -> URL? {
        if let savedURL { return savedURL }
        guard let destinationURL, let temporaryURL else {
            throw SessionAudioBufferError.notPrepared
        }
        guard sampleCount > 0 else {
            audioFile = nil
            try? FileManager.default.removeItem(at: temporaryURL)
            self.temporaryURL = nil
            return nil
        }

        try flushPendingSamples()
        audioFile = nil
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        self.temporaryURL = nil
        savedURL = destinationURL
        return destinationURL
    }

    public func replay(into engine: any SpeechRecognitionEngine) async throws {
        guard let url = try finishWriting() else {
            throw SessionAudioBufferError.noAudio
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(Self.replayChunkSize)
              ) else {
            throw SessionAudioBufferError.cannotCreateBuffer
        }

        var emittedSampleCount: Int64 = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let remainingFrameCount = file.length - file.framePosition
            let requestedFrameCount = min(
                AVAudioFramePosition(Self.replayChunkSize),
                remainingFrameCount
            )
            try file.read(
                into: buffer,
                frameCount: AVAudioFrameCount(requestedFrameCount)
            )
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }
            guard let channel = buffer.floatChannelData?[0] else {
                throw SessionAudioBufferError.cannotCreateBuffer
            }
            let samples = Array(UnsafeBufferPointer(start: channel, count: frameLength))
            try await engine.accept(
                AudioFrame(
                    samples: samples,
                    sampleRate: format.sampleRate,
                    capturedAt: Double(emittedSampleCount) / format.sampleRate
                )
            )
            emittedSampleCount += Int64(frameLength)
        }
    }

    public func reset() {
        clearState(removingTemporaryFile: true)
    }

    private func openAudioFile(sampleRate: Double) throws {
        guard let temporaryURL else {
            throw SessionAudioBufferError.notPrepared
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        audioFile = try AVAudioFile(
            forWriting: temporaryURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    private func flushPendingSamples() throws {
        guard !pendingSamples.isEmpty else { return }
        guard let audioFile else {
            throw SessionAudioBufferError.notPrepared
        }
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(pendingSamples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw SessionAudioBufferError.cannotCreateBuffer
        }
        buffer.frameLength = AVAudioFrameCount(pendingSamples.count)
        pendingSamples.withUnsafeBufferPointer { samples in
            channel.update(from: samples.baseAddress!, count: samples.count)
        }
        try audioFile.write(from: buffer)
        pendingSamples.removeAll(keepingCapacity: true)
    }

    private func clearState(removingTemporaryFile: Bool) {
        audioFile = nil
        if removingTemporaryFile, let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        temporaryURL = nil
        destinationURL = nil
        savedURL = nil
        sampleRate = nil
        sampleCount = 0
        pendingSamples.removeAll(keepingCapacity: false)
    }
}
