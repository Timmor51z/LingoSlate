import ClassBridgeCore
import Foundation

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

    public func reset() {
        frames.removeAll(keepingCapacity: false)
    }
}
