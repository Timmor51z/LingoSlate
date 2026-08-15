@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import LingoSlateCore
import Foundation

public struct MicrophoneInputDevice: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public enum MicrophoneDeviceCatalog {
    public static func availableInputDevices() -> [MicrophoneInputDevice] {
        CoreAudioInputDevices.devices().map { device in
            MicrophoneInputDevice(uid: device.uid, name: device.name)
        }
    }

    public static func defaultInputDeviceUID() -> String? {
        CoreAudioInputDevices.defaultDevice()?.uid
    }
}

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

public actor MicrophoneAudioCapture: RecordingAudioCaptureEngine {
    public nonisolated let events: AsyncStream<AudioCaptureEvent>
    public nonisolated let recordingFrames: AsyncStream<AudioFrame>

    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let recordingContinuation: AsyncStream<AudioFrame>.Continuation
    private var audioEngine: AVAudioEngine?
    private var tapState: TapState?
    private var configurationObserver: NSObjectProtocol?
    private var isRunning = false
    private var isFinished = false
    private let inputDeviceIsAvailable: @Sendable () -> Bool
    private let preferredDeviceUID: String?
    private var inputDeviceName: String?
    private var inputDeviceUID: String?
    private var inputSampleRate: Double?
    private var lastDiagnostics: AudioCaptureDiagnostics?

    public init(deviceUID: String? = nil) {
        let pair = AsyncStream<AudioCaptureEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let recordingPair = AsyncStream<AudioFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(1_024)
        )
        events = pair.stream
        continuation = pair.continuation
        recordingFrames = recordingPair.stream
        recordingContinuation = recordingPair.continuation
        inputDeviceIsAvailable = {
            AVCaptureDevice.default(for: .audio) != nil
        }
        preferredDeviceUID = deviceUID
    }

    init(inputDeviceIsAvailable: @escaping @Sendable () -> Bool) {
        let pair = AsyncStream<AudioCaptureEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let recordingPair = AsyncStream<AudioFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(1_024)
        )
        events = pair.stream
        continuation = pair.continuation
        recordingFrames = recordingPair.stream
        recordingContinuation = recordingPair.continuation
        self.inputDeviceIsAvailable = inputDeviceIsAvailable
        preferredDeviceUID = nil
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
        let selectedDevice = preferredDeviceUID.flatMap(CoreAudioInputDevices.device(forUID:))
            ?? CoreAudioInputDevices.defaultDevice()
        if preferredDeviceUID != nil, selectedDevice?.uid != preferredDeviceUID {
            throw MicrophoneCaptureError.unavailable
        }
        if let selectedDevice {
            try CoreAudioInputDevices.select(selectedDevice.id, for: inputNode)
        }
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
            continuation: continuation,
            recordingContinuation: recordingContinuation
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
        let fallbackDevice = AVCaptureDevice.default(for: .audio)
        inputDeviceName = selectedDevice?.name ?? fallbackDevice?.localizedName
        inputDeviceUID = selectedDevice?.uid ?? fallbackDevice?.uniqueID
        inputSampleRate = inputFormat.sampleRate
        lastDiagnostics = nil
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [continuation, inputNode, selectedDevice, tapState] _ in
            let currentDeviceID = CoreAudioInputDevices.currentDeviceID(for: inputNode)
            guard MicrophoneRouteChangePolicy.shouldFailCapture(
                expectedDeviceID: selectedDevice?.id,
                currentDeviceID: currentDeviceID
            ) else { return }
            tapState.recordRouteChange()
            continuation.yield(
                .failed(message: "麦克风设备发生变化，请重新开始课堂")
            )
        }
        isRunning = true
        continuation.yield(.started(sampleRate: outputFormat.sampleRate))
    }

    public func stop() async {
        guard !isFinished else { return }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if isRunning {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
        }
        lastDiagnostics = makeDiagnostics()
        audioEngine = nil
        tapState = nil
        isRunning = false
        isFinished = true
        continuation.yield(.stopped)
        continuation.finish()
        recordingContinuation.finish()
    }

    public func captureDiagnostics() async -> AudioCaptureDiagnostics? {
        lastDiagnostics ?? makeDiagnostics()
    }

    private func makeDiagnostics() -> AudioCaptureDiagnostics {
        let counters = tapState?.diagnosticCounters ?? (0, 0, 0)
        return AudioCaptureDiagnostics(
            inputDeviceName: inputDeviceName,
            inputDeviceUID: inputDeviceUID,
            inputSampleRate: inputSampleRate,
            recognitionDroppedFrameCount: counters.0,
            recordingDroppedFrameCount: counters.1,
            routeChangeCount: counters.2
        )
    }
}

private enum CoreAudioInputDevices {
    struct Device {
        var id: AudioDeviceID
        var uid: String
        var name: String
    }

    static func devices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInputStreams(id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: id),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: id) else {
                return nil
            }
            return Device(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultDevice() -> Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &id
        ) == noErr else { return nil }
        return devices().first { $0.id == id }
    }

    static func device(forUID uid: String) -> Device? {
        devices().first { $0.uid == uid }
    }

    static func select(_ deviceID: AudioDeviceID, for inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw MicrophoneCaptureError.unavailable
        }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MicrophoneCaptureError.unavailable
        }
    }

    static func currentDeviceID(for inputNode: AVAudioInputNode) -> AudioDeviceID? {
        guard let audioUnit = inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }
}

enum MicrophoneRouteChangePolicy {
    static func shouldFailCapture(
        expectedDeviceID: AudioDeviceID?,
        currentDeviceID: AudioDeviceID?
    ) -> Bool {
        guard let expectedDeviceID, let currentDeviceID else { return false }
        return expectedDeviceID != currentDeviceID
    }
}

private final class TapState: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let recordingContinuation: AsyncStream<AudioFrame>.Continuation
    private let diagnosticsLock = NSLock()
    private var recognitionDroppedFrameCount = 0
    private var recordingDroppedFrameCount = 0
    private var routeChangeCount = 0
    private var lastLevelEmissionTime: TimeInterval = 0

    init(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        continuation: AsyncStream<AudioCaptureEvent>.Continuation,
        recordingContinuation: AsyncStream<AudioFrame>.Continuation
    ) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.continuation = continuation
        self.recordingContinuation = recordingContinuation
    }

    var diagnosticCounters: (Int, Int, Int) {
        diagnosticsLock.withLock {
            (recognitionDroppedFrameCount, recordingDroppedFrameCount, routeChangeCount)
        }
    }

    func recordRouteChange() {
        diagnosticsLock.withLock {
            routeChangeCount += 1
        }
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
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelEmissionTime >= 0.1 {
            lastLevelEmissionTime = now
            continuation.yield(.inputLevel(frame.normalizedLevel))
        }
        if case .dropped = recordingContinuation.yield(frame) {
            diagnosticsLock.withLock {
                recordingDroppedFrameCount += 1
            }
        }
        if case .dropped = continuation.yield(.frame(frame)) {
            diagnosticsLock.withLock {
                recognitionDroppedFrameCount += 1
            }
        }
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
