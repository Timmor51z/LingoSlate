@preconcurrency import AVFoundation
import LingoSlateCore
import Foundation

public enum MicrophoneCaptureError: LocalizedError, Sendable {
    case permissionDenied
    case unavailable
    case invalidFormat
    case conversionFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有麦克风权限，请在系统设置的隐私与安全性中允许访问"
        case .unavailable:
            return "没有找到可用的麦克风"
        case .invalidFormat:
            return "麦克风返回了不支持的音频格式"
        case let .conversionFailed(message):
            return "音频转换失败：\(message)"
        case .cancelled:
            return "麦克风启动已取消"
        }
    }
}

public actor MicrophoneAudioCapture: AudioCaptureEngine {
    public nonisolated let events: AsyncStream<AudioCaptureEvent>

    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation
    private var audioEngine: AVAudioEngine?
    private var tapState: TapState?
    private var isRunning = false
    private var isFinished = false
    private let inputDeviceIsAvailable: @Sendable () -> Bool

    public init() {
        let pair = AsyncStream<AudioCaptureEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        inputDeviceIsAvailable = {
            AVCaptureDevice.default(for: .audio) != nil
        }
    }

    init(inputDeviceIsAvailable: @escaping @Sendable () -> Bool) {
        let pair = AsyncStream<AudioCaptureEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.inputDeviceIsAvailable = inputDeviceIsAvailable
    }

    public func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    public func start() async throws {
        guard !isRunning else { return }
        guard !isFinished else { throw MicrophoneCaptureError.cancelled }
        guard inputDeviceIsAvailable() else {
            throw MicrophoneCaptureError.unavailable
        }
        guard await requestPermission() else {
            throw MicrophoneCaptureError.permissionDenied
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneCaptureError.unavailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicrophoneCaptureError.invalidFormat
        }

        let tapState = TapState(
            converter: converter,
            outputFormat: outputFormat,
            continuation: continuation
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat
        ) { buffer, _ in
            tapState.consume(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }

        self.audioEngine = engine
        self.tapState = tapState
        isRunning = true
        continuation.yield(.started(sampleRate: outputFormat.sampleRate))
    }

    public func stop() async {
        guard !isFinished else { return }
        if isRunning {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
        }
        audioEngine = nil
        tapState = nil
        isRunning = false
        isFinished = true
        continuation.yield(.stopped)
        continuation.finish()
    }
}

private final class TapState: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation

    init(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        continuation: AsyncStream<AudioCaptureEvent>.Continuation
    ) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.continuation = continuation
    }

    func consume(_ inputBuffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            continuation.yield(.failed(message: MicrophoneCaptureError.invalidFormat.localizedDescription))
            return
        }

        let inputProvider = ConverterInputProvider(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            inputProvider.next(inputStatus)
        }

        if status == .error {
            let message = conversionError?.localizedDescription ?? "未知错误"
            continuation.yield(
                .failed(message: MicrophoneCaptureError.conversionFailed(message).localizedDescription)
            )
            return
        }

        guard outputBuffer.frameLength > 0,
              let channel = outputBuffer.floatChannelData?[0] else { return }

        let samples = Array(
            UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))
        )
        let frame = AudioFrame(
            samples: samples,
            sampleRate: outputFormat.sampleRate,
            capturedAt: ProcessInfo.processInfo.systemUptime
        )
        continuation.yield(.inputLevel(frame.normalizedLevel))
        continuation.yield(
            .frame(frame)
        )
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
