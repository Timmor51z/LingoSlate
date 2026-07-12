import LingoSlateAudio
import LingoSlateCore
import FluidAudio
import Foundation

@main
struct LingoSlateASRSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: swift run LingoSlateASRSmoke <audio-file>")
            return
        }

        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        let engine = FluidAudioRecognitionEngine()

        let eventTask = Task {
            for await event in engine.events {
                switch event {
                case .started:
                    print("ASR ready")
                case let .provisional(_, text, _, _, _):
                    print("PARTIAL: \(text)")
                case let .final(_, text, startTime, endTime, _, _):
                    print(String(format: "FINAL %.2f-%.2f: %@", startTime, endTime, text))
                case let .failed(message):
                    print("FAILED: \(message)")
                case .finished:
                    print("ASR finished")
                }
            }
        }

        try await engine.start(
            configuration: RecognitionConfiguration(
                course: Course(name: "LingoSlate ASR smoke test")
            )
        )

        let sampleRate = 16_000.0
        let frameSize = 3_200
        var offset = 0
        while offset < samples.count {
            let end = min(offset + frameSize, samples.count)
            let frame = AudioFrame(
                samples: Array(samples[offset..<end]),
                sampleRate: sampleRate,
                capturedAt: Double(offset) / sampleRate
            )
            try await engine.accept(frame)
            offset = end
        }

        try await engine.finalize()
        await eventTask.value
    }
}
