import LingoSlateCore
import Foundation

public enum SonioxRecognitionError: LocalizedError, Sendable {
    case missingAPIKey
    case notStarted
    case invalidSampleRate(Double)
    case audioBacklogExceeded
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未配置 Soniox API Key"
        case .notStarted:
            return "Soniox 转写尚未启动"
        case let .invalidSampleRate(sampleRate):
            return "Soniox 需要 16 kHz 音频，当前为 \(Int(sampleRate)) Hz"
        case .audioBacklogExceeded:
            return "Soniox 音频上传持续拥堵，请检查网络后重新开始课堂"
        case let .server(message):
            return "Soniox 转写失败：\(message)"
        }
    }
}

public actor SonioxRecognitionEngine: SpeechRecognitionEngine {
    public nonisolated let events: AsyncStream<RecognitionEvent>

    private static let endpointURL = URL(
        string: "wss://stt-rt.soniox.com/transcribe-websocket"
    )!
    fileprivate static let sampleRate = 16_000.0
    private static let audioBatchSampleCount = 1_600
    private static let audioQueueCapacity = 1_024

    private let apiKey: String
    private let session: URLSession
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<[Float]>.Continuation?
    private var audioSendTask: Task<Void, Never>?
    private var assembler = SonioxUtteranceAssembler()
    private var startRequestData: Data?
    private var expectsTranslation = false
    private var sentSampleCount = 0
    private var reconnectTask: Task<Void, Error>?
    private var reconnectGeneration = 0
    private var consecutiveReconnectAttempts = 0
    private var isFinalizing = false
    private var isFinished = false
    private var terminalError: SonioxRecognitionError?

    public init(apiKey: String, session: URLSession = .shared) {
        let pair = AsyncStream<RecognitionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        events = pair.stream
        continuation = pair.continuation
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func start(configuration: RecognitionConfiguration) async throws {
        guard socket == nil else { return }
        guard !apiKey.isEmpty else { throw SonioxRecognitionError.missingAPIKey }

        assembler = SonioxUtteranceAssembler(
            expectsTranslation: configuration.translationTargetLanguage != nil
        )
        expectsTranslation = configuration.translationTargetLanguage != nil
        sentSampleCount = 0
        consecutiveReconnectAttempts = 0
        startRequestData = try SonioxStartRequestBuilder.make(
            apiKey: apiKey,
            configuration: configuration
        )
        let socket = try await openSocket()

        self.socket = socket
        let audioPair = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.audioQueueCapacity)
        )
        audioContinuation = audioPair.continuation
        audioSendTask = Task { [weak self] in
            await self?.sendAudio(audioPair.stream)
        }
        startReceiving(from: socket)
        continuation.yield(.started)
    }

    public func accept(_ frame: AudioFrame) async throws {
        if let terminalError { throw terminalError }
        guard let audioContinuation else {
            throw SonioxRecognitionError.notStarted
        }
        guard !isFinalizing, !isFinished else { return }
        guard abs(frame.sampleRate - Self.sampleRate) < 1 else {
            throw SonioxRecognitionError.invalidSampleRate(frame.sampleRate)
        }
        guard !frame.samples.isEmpty else { return }
        if case .dropped = audioContinuation.yield(frame.samples) {
            let error = SonioxRecognitionError.audioBacklogExceeded
            fail(error)
            throw error
        }
    }

    public func finalize() async throws {
        if let terminalError { throw terminalError }
        guard !isFinished else { return }
        guard socket != nil else { throw SonioxRecognitionError.notStarted }
        isFinalizing = true
        audioContinuation?.finish()
        audioContinuation = nil
        await audioSendTask?.value
        audioSendTask = nil
        if let terminalError { throw terminalError }
        guard let socket else { throw SonioxRecognitionError.notStarted }
        try await socket.send(.string(""))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while !isFinished, terminalError == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if !isFinished, terminalError == nil {
            receiveTask?.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            fail("finalization_timeout: 等待最终转写结果超时")
        }
        if let terminalError { throw terminalError }
    }

    private func sendAudio(_ stream: AsyncStream<[Float]>) async {
        var batcher = SonioxAudioBatcher(targetSampleCount: Self.audioBatchSampleCount)
        do {
            for await samples in stream {
                try Task.checkCancellation()
                for batch in batcher.append(samples) {
                    try await send(batch)
                }
            }
            if let finalBatch = batcher.finish() {
                try await send(finalBatch)
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error as? SonioxRecognitionError ?? .server(error.localizedDescription))
        }
    }

    private func send(_ samples: [Float]) async throws {
        while true {
            try Task.checkCancellation()
            let currentSocket: URLSessionWebSocketTask
            if let socket {
                currentSocket = socket
            } else {
                try await reconnect(after: nil, failedSocket: nil)
                guard let socket else { throw SonioxRecognitionError.notStarted }
                currentSocket = socket
            }
            do {
                try await currentSocket.send(.data(SonioxPCMEncoder.encode(samples)))
                sentSampleCount += samples.count
                return
            } catch {
                try await reconnect(after: error, failedSocket: currentSocket)
            }
        }
    }

    private func openSocket() async throws -> URLSessionWebSocketTask {
        guard let startRequestData else { throw SonioxRecognitionError.notStarted }
        let socket = session.webSocketTask(with: Self.endpointURL)
        socket.resume()
        do {
            try await socket.send(
                .string(String(decoding: startRequestData, as: UTF8.self))
            )
            return socket
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    private func startReceiving(from socket: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self, socket] in
            await self?.receiveMessages(from: socket)
        }
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled, !isFinished {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .data(value):
                    data = value
                case let .string(value):
                    data = Data(value.utf8)
                @unknown default:
                    continue
                }
                try receive(data)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isFinished else { return }
            do {
                try await reconnect(after: error, failedSocket: socket)
            } catch is CancellationError {
                return
            } catch {
                fail(error as? SonioxRecognitionError ?? .server(error.localizedDescription))
            }
        }
    }

    private func receive(_ data: Data) throws {
        let response = try JSONDecoder().decode(SonioxResponse.self, from: data)
        if let errorType = response.errorType {
            let message = [errorType, response.errorMessage]
                .compactMap { $0 }
                .joined(separator: ": ")
            if SonioxReconnectPolicy.shouldReconnect(errorType: errorType) {
                throw SonioxRetriableServerError(message: message)
            }
            fail(message)
            return
        }
        consecutiveReconnectAttempts = 0

        for event in assembler.consume(response) {
            switch event {
            case let .provisional(id, text, startTime, endTime, provider):
                continuation.yield(
                    .provisional(
                        id: id,
                        text: text,
                        startTime: startTime,
                        endTime: endTime,
                        provider: provider
                    )
                )
            case let .final(id, text, startTime, endTime, speaker, provider):
                continuation.yield(
                    .final(
                        id: id,
                        text: text,
                        startTime: startTime,
                        endTime: endTime,
                        speaker: speaker,
                        provider: provider
                    )
                )
            case let .bilingualProvisional(result):
                continuation.yield(.bilingualProvisional(result))
            case let .bilingualFinal(result):
                continuation.yield(.bilingualFinal(result))
            }
        }
        if response.finished == true {
            finishSuccessfully()
        }
    }

    private func reconnect(
        after error: Error?,
        failedSocket: URLSessionWebSocketTask?
    ) async throws {
        guard !isFinished else { throw CancellationError() }
        if let currentSocket = socket,
           let failedSocket,
           currentSocket !== failedSocket {
            return
        }
        if let reconnectTask {
            try await reconnectTask.value
            return
        }

        if let failedSocket, socket === failedSocket {
            socket = nil
            failedSocket.cancel(with: .goingAway, reason: nil)
        }
        reconnectGeneration += 1
        let generation = reconnectGeneration
        let lastErrorMessage = error?.localizedDescription ?? "连接已断开"
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performReconnect(lastErrorMessage: lastErrorMessage)
        }
        reconnectTask = task
        do {
            try await task.value
            if reconnectGeneration == generation { reconnectTask = nil }
        } catch {
            if reconnectGeneration == generation { reconnectTask = nil }
            throw error
        }
    }

    private func performReconnect(lastErrorMessage: String) async throws {
        var latestErrorMessage = lastErrorMessage
        while consecutiveReconnectAttempts < SonioxReconnectPolicy.maximumAttempts {
            consecutiveReconnectAttempts += 1
            let attempt = consecutiveReconnectAttempts
            try Task.checkCancellation()
            try await Task.sleep(
                for: .milliseconds(
                    SonioxReconnectPolicy.delayMilliseconds(forAttempt: attempt)
                )
            )
            do {
                let newSocket = try await openSocket()
                if let partial = assembler.finish() {
                    continuation.yield(partial.recognitionEvent)
                }
                assembler = SonioxUtteranceAssembler(
                    expectsTranslation: expectsTranslation,
                    timeOffset: Double(sentSampleCount) / Self.sampleRate
                )
                socket = newSocket
                startReceiving(from: newSocket)
                continuation.yield(.started)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                latestErrorMessage = error.localizedDescription
            }
        }
        throw SonioxRecognitionError.server(
            "网络中断，自动重连 \(SonioxReconnectPolicy.maximumAttempts) 次仍失败：\(latestErrorMessage)"
        )
    }

    private func finishSuccessfully() {
        guard !isFinished else { return }
        isFinished = true
        if let final = assembler.finish() {
            continuation.yield(final.recognitionEvent)
        }
        continuation.yield(.finished)
        continuation.finish()
        audioContinuation?.finish()
        audioContinuation = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        socket = nil
        receiveTask = nil
    }

    private func fail(_ message: String) {
        fail(.server(message))
    }

    private func fail(_ error: SonioxRecognitionError) {
        guard !isFinished else { return }
        isFinished = true
        terminalError = error
        if let final = assembler.finish() {
            continuation.yield(final.recognitionEvent)
        }
        continuation.yield(.failed(message: error.localizedDescription))
        continuation.finish()
        audioContinuation?.finish()
        audioContinuation = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask = nil
    }
}

private struct SonioxRetriableServerError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

enum SonioxReconnectPolicy {
    static let maximumAttempts = 3

    static func shouldReconnect(errorType: String) -> Bool {
        switch errorType {
        case "service_unavailable", "request_timeout", "internal_error",
             "max_duration_reached", "limit_exceeded":
            return true
        default:
            return false
        }
    }

    static func delayMilliseconds(forAttempt attempt: Int) -> Int {
        1_000 * (1 << min(max(attempt - 1, 0), maximumAttempts - 1))
    }
}

enum SonioxStartRequestBuilder {
    static func make(
        apiKey: String,
        configuration: RecognitionConfiguration
    ) throws -> Data {
        var terms: [String] = []
        var seen: Set<String> = []
        for term in (configuration.course.recognitionTerms ?? [])
            + configuration.approvedTerms.flatMap({ [$0.source] + $0.aliases }) {
            guard let term = recognitionHint(
                for: term.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else { continue }
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(String(term.prefix(120)))
        }

        var general: [[String: String]] = []
        func append(_ key: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return }
            general.append(["key": key, "value": String(value.prefix(500))])
        }
        append("course", configuration.course.name)
        append("course_code", configuration.course.code)
        append("domain", configuration.course.domain)
        append("description", configuration.course.roughDescription)
        append("lecturer", configuration.course.lecturerNames.joined(separator: ", "))
        append("lecturer_accent", configuration.course.lecturerAccent?.displayName)

        var context: [String: Any] = [:]
        if !general.isEmpty { context["general"] = general }
        if !terms.isEmpty { context["terms"] = Array(terms.prefix(200)) }
        if configuration.translationTargetLanguage != nil {
            var translationTerms: [[String: String]] = []
            var seenTranslationSources: Set<String> = []
            for term in configuration.approvedTerms {
                let target = term.target.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else { continue }
                for source in [term.source] + term.aliases {
                    let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !source.isEmpty,
                          seenTranslationSources.insert(source.lowercased()).inserted else {
                        continue
                    }
                    translationTerms.append([
                        "source": String(source.prefix(120)),
                        "target": String(target.prefix(120)),
                    ])
                }
            }
            if !translationTerms.isEmpty {
                context["translation_terms"] = Array(translationTerms.prefix(200))
            }
        }

        var request: [String: Any] = [
            "api_key": apiKey,
            "model": "stt-rt-v5",
            "audio_format": "pcm_s16le",
            "sample_rate": Int(SonioxRecognitionEngine.sampleRate),
            "num_channels": 1,
            "language_hints": ["en", "zh"],
            "language_hints_strict": true,
            "enable_language_identification": true,
            "enable_speaker_diarization": true,
            "enable_endpoint_detection": true,
            "endpoint_latency_adjustment_level": 1,
            "endpoint_sensitivity": 0.0,
            "max_endpoint_delay_ms": 1_000,
            "client_reference_id": "lingoslate",
        ]
        if let targetLanguage = configuration.translationTargetLanguage {
            request["translation"] = [
                "type": "one_way",
                "target_language": targetLanguage,
            ]
        }
        if !context.isEmpty { request["context"] = context }
        return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    }

    private static func recognitionHint(for term: String) -> String? {
        switch term.lowercased() {
        case "cloudtrail", "cloud trail", "aws cloudtrail":
            return nil
        default:
            return term
        }
    }
}

struct SonioxAudioBatcher {
    private let targetSampleCount: Int
    private var pendingSamples: [Float] = []

    init(targetSampleCount: Int) {
        self.targetSampleCount = max(1, targetSampleCount)
        pendingSamples.reserveCapacity(self.targetSampleCount * 2)
    }

    mutating func append(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        pendingSamples.append(contentsOf: samples)

        var batches: [[Float]] = []
        var consumed = 0
        while pendingSamples.count - consumed >= targetSampleCount {
            let end = consumed + targetSampleCount
            batches.append(Array(pendingSamples[consumed..<end]))
            consumed = end
        }
        if consumed > 0 {
            pendingSamples.removeFirst(consumed)
        }
        return batches
    }

    mutating func finish() -> [Float]? {
        guard !pendingSamples.isEmpty else { return nil }
        defer { pendingSamples.removeAll(keepingCapacity: false) }
        return pendingSamples
    }
}

private enum SonioxPCMEncoder {
    static func encode(_ samples: [Float]) -> Data {
        let values = samples.map { sample -> Int16 in
            let clipped = min(max(sample, -1), 1)
            return Int16((clipped * Float(Int16.max)).rounded()).littleEndian
        }
        return values.withUnsafeBytes { Data($0) }
    }
}

struct SonioxResponse: Decodable {
    var tokens: [SonioxToken] = []
    var finalAudioProcessedMilliseconds: Double? = nil
    var totalAudioProcessedMilliseconds: Double? = nil
    var finished: Bool? = nil
    var errorType: String? = nil
    var errorMessage: String? = nil

    enum CodingKeys: String, CodingKey {
        case tokens
        case finalAudioProcessedMilliseconds = "final_audio_proc_ms"
        case totalAudioProcessedMilliseconds = "total_audio_proc_ms"
        case finished
        case errorType = "error_type"
        case errorMessage = "error_message"
    }
}

struct SonioxToken: Decodable, Equatable {
    var text: String
    var startMilliseconds: Double?
    var endMilliseconds: Double?
    var isFinal: Bool
    var speaker: String?
    var language: String?
    var translationStatus: String? = nil
    var sourceLanguage: String? = nil

    enum CodingKeys: String, CodingKey {
        case text
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case isFinal = "is_final"
        case speaker
        case language
        case translationStatus = "translation_status"
        case sourceLanguage = "source_language"
    }
}

enum SonioxAssembledEvent: Equatable {
    static let provider = "soniox-stt-rt-v5"
    static let translationProvider = "soniox-translation-stt-rt-v5"

    case provisional(
        id: UUID,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        provider: String
    )
    case final(
        id: UUID,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speaker: String?,
        provider: String
    )
    case bilingualProvisional(BilingualRecognitionResult)
    case bilingualFinal(BilingualRecognitionResult)

    var recognitionEvent: RecognitionEvent {
        switch self {
        case let .provisional(id, text, startTime, endTime, provider):
            return .provisional(
                id: id,
                text: text,
                startTime: startTime,
                endTime: endTime,
                provider: provider
            )
        case let .final(id, text, startTime, endTime, speaker, provider):
            return .final(
                id: id,
                text: text,
                startTime: startTime,
                endTime: endTime,
                speaker: speaker,
                provider: provider
            )
        case let .bilingualProvisional(result):
            return .bilingualProvisional(result)
        case let .bilingualFinal(result):
            return .bilingualFinal(result)
        }
    }
}

struct SonioxUtteranceAssembler {
    private static let softCommitMinimumDuration: TimeInterval = 12

    private let expectsTranslation: Bool
    private let timeOffset: TimeInterval
    private var segmentID = UUID()
    private var finalSourceTokens: [SonioxToken] = []
    private var finalTranslationTokens: [SonioxToken] = []
    private var lastAudioTime: TimeInterval = 0

    init(expectsTranslation: Bool = false, timeOffset: TimeInterval = 0) {
        self.expectsTranslation = expectsTranslation
        self.timeOffset = max(0, timeOffset)
    }

    mutating func consume(_ response: SonioxResponse) -> [SonioxAssembledEvent] {
        lastAudioTime = max(
            lastAudioTime,
            timeOffset + (response.totalAudioProcessedMilliseconds ?? 0) / 1_000
        )
        var events: [SonioxAssembledEvent] = []
        var provisionalSourceTokens: [SonioxToken] = []
        var provisionalTranslationTokens: [SonioxToken] = []
        var reachedEndpoint = false

        for token in response.tokens {
            if token.isFinal, token.text == "<end>" || token.text == "<fin>" {
                reachedEndpoint = true
            } else if token.translationStatus == "translation" {
                if token.isFinal {
                    finalTranslationTokens.append(token)
                } else {
                    provisionalTranslationTokens.append(token)
                }
            } else if token.isFinal {
                finalSourceTokens.append(token)
            } else {
                provisionalSourceTokens.append(token)
            }
        }

        if reachedEndpoint {
            finalSourceTokens.append(contentsOf: provisionalSourceTokens)
            finalTranslationTokens.append(contentsOf: provisionalTranslationTokens)
            if let final = flush() { events.append(final) }
            return events
        }

        if shouldSoftCommit(), let final = flush() {
            events.append(final)
        }

        let visibleSourceTokens = finalSourceTokens + provisionalSourceTokens
        let visibleTranslationTokens = finalTranslationTokens + provisionalTranslationTokens
        if let text = joinedText(visibleSourceTokens) {
            let times = timeRange(visibleSourceTokens)
            if expectsTranslation {
                events.append(
                    .bilingualProvisional(
                        bilingualResult(
                            sourceText: text,
                            translatedText: joinedText(visibleTranslationTokens),
                            sourceTokens: visibleSourceTokens,
                            startTime: times.start,
                            endTime: times.end
                        )
                    )
                )
            } else {
                events.append(
                    .provisional(
                        id: segmentID,
                        text: text,
                        startTime: times.start,
                        endTime: times.end,
                        provider: SonioxAssembledEvent.provider
                    )
                )
            }
        }
        return events
    }

    mutating func finish() -> SonioxAssembledEvent? {
        flush()
    }

    private mutating func flush() -> SonioxAssembledEvent? {
        defer {
            finalSourceTokens.removeAll(keepingCapacity: true)
            finalTranslationTokens.removeAll(keepingCapacity: true)
            segmentID = UUID()
        }
        guard let text = joinedText(finalSourceTokens) else { return nil }
        let times = timeRange(finalSourceTokens)
        if expectsTranslation {
            return .bilingualFinal(
                bilingualResult(
                    sourceText: text,
                    translatedText: joinedText(finalTranslationTokens),
                    sourceTokens: finalSourceTokens,
                    startTime: times.start,
                    endTime: times.end
                )
            )
        }
        return .final(
            id: segmentID,
            text: text,
            startTime: times.start,
            endTime: times.end,
            speaker: dominantSpeaker(finalSourceTokens),
            provider: SonioxAssembledEvent.provider
        )
    }

    private func bilingualResult(
        sourceText: String,
        translatedText: String?,
        sourceTokens: [SonioxToken],
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> BilingualRecognitionResult {
        BilingualRecognitionResult(
            id: segmentID,
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguage: dominantLanguage(sourceTokens),
            startTime: startTime,
            endTime: endTime,
            speaker: dominantSpeaker(sourceTokens),
            recognitionProvider: SonioxAssembledEvent.provider,
            translationProvider: SonioxAssembledEvent.translationProvider
        )
    }

    private func joinedText(_ tokens: [SonioxToken]) -> String? {
        let text = tokens.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func timeRange(_ tokens: [SonioxToken]) -> (start: TimeInterval, end: TimeInterval) {
        let start = tokens.compactMap(\.startMilliseconds).min()
            .map { timeOffset + $0 / 1_000 }
            ?? lastAudioTime
        let end = tokens.compactMap(\.endMilliseconds).max()
            .map { timeOffset + $0 / 1_000 }
            ?? lastAudioTime
        return (max(0, start), max(start, end))
    }

    private func dominantSpeaker(_ tokens: [SonioxToken]) -> String? {
        let counts = tokens.compactMap(\.speaker).reduce(into: [String: Int]()) {
            $0[$1, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private func dominantLanguage(_ tokens: [SonioxToken]) -> String? {
        let counts = tokens.compactMap(\.language).reduce(into: [String: Int]()) {
            $0[$1, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
            ?? finalTranslationTokens.compactMap(\.sourceLanguage).first
    }

    private func shouldSoftCommit() -> Bool {
        guard let sourceText = joinedText(finalSourceTokens),
              hasSentenceTerminator(sourceText) else { return false }
        let times = timeRange(finalSourceTokens)
        guard times.end - times.start >= Self.softCommitMinimumDuration else {
            return false
        }
        guard expectsTranslation else { return true }
        guard let translatedText = joinedText(finalTranslationTokens) else { return false }
        return hasSentenceTerminator(translatedText)
    }

    private func hasSentenceTerminator(_ text: String) -> Bool {
        let trailingCharacters = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\"'”’)]}》」』")
        )
        guard let finalCharacter = text
            .trimmingCharacters(in: trailingCharacters)
            .last else { return false }
        return ".!?。！？".contains(finalCharacter)
    }
}
