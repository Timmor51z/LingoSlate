import ClassBridgeCore
import Foundation

struct DemoTranslationEngine: TranslationEngine {
    let identifier = "demo-translation"

    private let translations: [String: String] = [
        "Today we will look at how an event loop schedules asynchronous work.":
            "今天我们将了解事件循环如何调度异步任务。",
        "The call stack must be empty before the queued callback can run.":
            "调用栈必须清空后，队列中的回调才能运行。",
        "This distinction becomes important when we debug timing problems.":
            "当我们调试时序问题时，这一区别会变得很重要。",
        "Please mark this diagram because it will be useful for the assignment.":
            "请标记这张图，因为它会对作业有所帮助。",
    ]

    func translate(_ text: String, context: TranslationContext) async throws -> String {
        translations[text] ?? "［等待本地翻译模型］"
    }
}
actor DemoRecognitionEngine: SpeechRecognitionEngine {
    nonisolated let events: AsyncStream<RecognitionEvent>

    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private var playbackTask: Task<Void, Never>?

    init() {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start(configuration: RecognitionConfiguration) async throws {
        guard playbackTask == nil else { return }
        continuation.yield(.started)
        playbackTask = Task {
            await playScript()
        }
    }

    func accept(_ frame: AudioFrame) async throws {
        // The production FluidAudio adapter consumes frames here.
    }

    func finalize() async throws {
        playbackTask?.cancel()
        playbackTask = nil
        continuation.yield(.finished)
        continuation.finish()
    }

    private func playScript() async {
        let script = [
            "Today we will look at how an event loop schedules asynchronous work.",
            "The call stack must be empty before the queued callback can run.",
            "This distinction becomes important when we debug timing problems.",
            "Please mark this diagram because it will be useful for the assignment.",
        ]

        var cursor: TimeInterval = 0

        for line in script {
            guard !Task.isCancelled else { return }

            let id = UUID()
            let words = line.split(separator: " ")
            let previewCount = max(3, words.count / 2)
            let preview = words.prefix(previewCount).joined(separator: " ")
            let duration = max(2.2, Double(words.count) * 0.28)

            continuation.yield(
                .provisional(
                    id: id,
                    text: preview,
                    startTime: cursor,
                    endTime: cursor + duration * 0.5,
                    provider: "demo"
                )
            )
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }

            continuation.yield(
                .provisional(
                    id: id,
                    text: line,
                    startTime: cursor,
                    endTime: cursor + duration,
                    provider: "demo"
                )
            )
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }

            continuation.yield(
                .final(
                    id: id,
                    text: line,
                    startTime: cursor,
                    endTime: cursor + duration,
                    speaker: nil,
                    provider: "demo"
                )
            )

            cursor += duration
            try? await Task.sleep(for: .milliseconds(500))
        }

        playbackTask = nil
        continuation.yield(.finished)
        continuation.finish()
    }
}
