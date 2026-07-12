import LingoSlateCore
import Foundation

public actor AudioEnhancingRecognitionEngine: SpeechRecognitionEngine {
    public nonisolated let events: AsyncStream<RecognitionEvent>

    private let base: any SpeechRecognitionEngine
    private var processor: AdaptiveGainProcessor

    public init(
        base: any SpeechRecognitionEngine,
        configuration: AdaptiveGainConfiguration = .classroom
    ) {
        self.base = base
        events = base.events
        processor = AdaptiveGainProcessor(configuration: configuration)
    }

    public func start(configuration: RecognitionConfiguration) async throws {
        try await base.start(configuration: configuration)
    }

    public func accept(_ frame: AudioFrame) async throws {
        try await base.accept(processor.process(frame))
    }

    public func finalize() async throws {
        try await base.finalize()
    }
}
