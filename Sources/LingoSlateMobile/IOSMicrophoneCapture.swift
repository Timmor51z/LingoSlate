#if os(iOS)
import AVFAudio
import AudioToolbox
import Foundation
import LingoSlateCore

public actor IOSMicrophoneCapture: AudioCaptureEngine {
    public nonisolated let events: AsyncStream<AudioCaptureEvent>

    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let recordingURL: URL
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var isRunning = false
    private var inputSampleRate: Double?

    public init(recordingURL: URL) {
        let pair = AsyncStream<AudioCaptureEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        events = pair.stream
        continuation = pair.continuation
        self.recordingURL = recordingURL
    }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
    }

    public func start() async throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(16_000)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw IOSMicrophoneError.invalidFormat
        }
        try FileManager.default.createDirectory(
            at: recordingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let recordingFile = try AVAudioFile(
            forWriting: recordingURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVEncoderBitRateKey: 64_000,
            ],
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )

        let tap = IOSTapState(
            converter: converter,
            outputFormat: outputFormat,
            recordingFile: recordingFile,
            continuation: continuation
        )
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { buffer, _ in
            tap.consume(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false)
            throw error
        }

        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [continuation] notification in
            guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
            continuation.yield(.failed(message: "录音被系统中断，请重新开始课堂"))
        }
        self.engine = engine
        inputSampleRate = inputFormat.sampleRate
        isRunning = true
        continuation.yield(.started(sampleRate: 16_000))
    }

    public func stop() async {
        guard isRunning else { return }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        continuation.yield(.stopped)
        continuation.finish()
    }

    public func captureDiagnostics() async -> AudioCaptureDiagnostics? {
        AudioCaptureDiagnostics(
            inputDeviceName: AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName,
            inputDeviceUID: AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid,
            inputSampleRate: inputSampleRate
        )
    }
}

private enum IOSMicrophoneError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        "无法读取当前麦克风音频格式"
    }
}

private final class IOSTapState: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let recordingFile: AVAudioFile
    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation
    private var lastLevelEmissionTime: TimeInterval = 0

    init(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        recordingFile: AVAudioFile,
        continuation: AsyncStream<AudioCaptureEvent>.Continuation
    ) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.recordingFile = recordingFile
        self.continuation = continuation
    }

    func consume(_ inputBuffer: AVAudioPCMBuffer) {
        do {
            try recordingFile.write(from: inputBuffer)
        } catch {
            continuation.yield(.failed(message: "课堂录音保存失败：\(error.localizedDescription)"))
            return
        }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return }

        let provider = IOSConverterInputProvider(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            provider.next(status)
        }
        guard status != .error,
              outputBuffer.frameLength > 0,
              let channel = outputBuffer.floatChannelData?[0] else {
            if let conversionError {
                continuation.yield(.failed(message: conversionError.localizedDescription))
            }
            return
        }

        let frame = AudioFrame(
            samples: Array(UnsafeBufferPointer(
                start: channel,
                count: Int(outputBuffer.frameLength)
            )),
            sampleRate: outputFormat.sampleRate,
            capturedAt: ProcessInfo.processInfo.systemUptime
        )
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelEmissionTime >= 0.1 {
            lastLevelEmissionTime = now
            continuation.yield(.inputLevel(frame.normalizedLevel))
        }
        continuation.yield(.frame(frame))
    }
}

private final class IOSConverterInputProvider: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
#endif
