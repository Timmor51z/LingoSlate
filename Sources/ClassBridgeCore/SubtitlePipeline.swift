import Foundation

public actor SubtitlePipeline {
    private let course: Course
    private let translationEngine: any TranslationEngine
    private let approvedTerms: [GlossaryTerm]
    private let recentContextLimit: Int
    private let termNormalizer: TranscriptTermNormalizer

    private var finalSegments: [TranscriptSegment] = []
    private var provisionalSegment: TranscriptSegment?
    private var continuations: [UUID: AsyncStream<TranscriptSnapshot>.Continuation] = [:]
    private var translationTasks: [UUID: PendingTranslation] = [:]

    public init(
        course: Course,
        translationEngine: any TranslationEngine,
        approvedTerms: [GlossaryTerm] = [],
        recentContextLimit: Int = 4
    ) {
        self.course = course
        self.translationEngine = translationEngine
        self.approvedTerms = approvedTerms.filter(\.isApproved)
        self.recentContextLimit = max(0, recentContextLimit)
        self.termNormalizer = TranscriptTermNormalizer(course: course)
    }

    public func snapshots() -> AsyncStream<TranscriptSnapshot> {
        let subscriptionID = UUID()
        let initialSnapshot = makeSnapshot()

        let pair = AsyncStream<TranscriptSnapshot>.makeStream()
        continuations[subscriptionID] = pair.continuation
        pair.continuation.yield(initialSnapshot)
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(subscriptionID)
            }
        }
        return pair.stream
    }

    public func currentSnapshot() -> TranscriptSnapshot {
        makeSnapshot()
    }

    public func consume(_ event: RecognitionEvent) async {
        switch event {
        case .started:
            break

        case let .provisional(id, text, startTime, endTime, provider):
            provisionalSegment = TranscriptSegment(
                id: id,
                startTime: startTime,
                endTime: endTime,
                sourceText: text,
                state: .provisional,
                provider: provider
            )
            publish()

        case let .final(id, text, startTime, endTime, speaker, provider):
            provisionalSegment = nil
            let normalizedText = termNormalizer.normalize(text)

            let segment = TranscriptSegment(
                id: id,
                startTime: startTime,
                endTime: endTime,
                sourceText: normalizedText,
                speaker: speaker,
                state: .final,
                provider: provider
            )
            upsertFinalSegment(segment)
            publish()

            let context = TranslationContext(
                course: course,
                recentSourceText: Array(
                    finalSegments.dropLast().suffix(recentContextLimit).map(\.sourceText)
                ),
                approvedTerms: approvedTerms
            )

            scheduleTranslation(
                text: normalizedText,
                segmentID: id,
                context: context
            )

        case .failed:
            provisionalSegment = nil
            publish()

        case .finished:
            provisionalSegment = nil
            publish()
        }
    }

    public func reset() {
        cancelPendingTranslations()
        finalSegments.removeAll()
        provisionalSegment = nil
        publish()
    }

    public func finishPendingTranslations() async {
        while !translationTasks.isEmpty {
            let tasks = translationTasks.values.map(\.task)
            for task in tasks {
                await task.value
            }
        }
    }

    @discardableResult
    public func replaceFinalTranscript(
        with text: String,
        duration: TimeInterval,
        provider: String,
        maximumWordsPerSegment: Int = 36
    ) async -> Bool {
        cancelPendingTranslations()
        let text = termNormalizer.normalize(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !finalSegments.contains(where: \.isUserCorrected) else {
            return false
        }

        let chunks = Self.transcriptChunks(
            text,
            maximumWordsPerSegment: maximumWordsPerSegment
        )
        guard !chunks.isEmpty else { return false }

        let wordCounts = chunks.map(Self.wordCount)
        let totalWordCount = max(1, wordCounts.reduce(0, +))
        var elapsedWordCount = 0

        finalSegments = chunks.enumerated().map { index, chunk in
            let startTime = duration * Double(elapsedWordCount) / Double(totalWordCount)
            elapsedWordCount += wordCounts[index]
            let endTime = index == chunks.indices.last
                ? duration
                : duration * Double(elapsedWordCount) / Double(totalWordCount)
            return TranscriptSegment(
                startTime: startTime,
                endTime: max(startTime, endTime),
                sourceText: chunk,
                state: .final,
                provider: provider
            )
        }
        provisionalSegment = nil
        publish()

        for index in finalSegments.indices {
            let segment = finalSegments[index]
            let context = TranslationContext(
                course: course,
                recentSourceText: Array(
                    finalSegments[..<index].suffix(recentContextLimit).map(\.sourceText)
                ),
                approvedTerms: approvedTerms
            )

            do {
                let translation = try await translationEngine.translate(
                    segment.sourceText,
                    context: context
                )
                applyTranslation(translation, to: segment.id)
                publish()
            } catch {
                // Keep the improved English segment. Translation can be retried later.
            }
        }
        return true
    }

    private func upsertFinalSegment(_ segment: TranscriptSegment) {
        if let index = finalSegments.firstIndex(where: { $0.id == segment.id }) {
            guard !finalSegments[index].isUserCorrected else { return }
            finalSegments[index] = segment
        } else {
            finalSegments.append(segment)
        }
        finalSegments.sort { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.startTime < rhs.startTime
        }
    }

    private func applyTranslation(_ translation: String, to segmentID: UUID) {
        guard let index = finalSegments.firstIndex(where: { $0.id == segmentID }) else {
            return
        }
        finalSegments[index].translatedText = translation
        finalSegments[index].state = .translated
    }

    private func scheduleTranslation(
        text: String,
        segmentID: UUID,
        context: TranslationContext
    ) {
        translationTasks[segmentID]?.task.cancel()
        let token = UUID()
        let engine = translationEngine
        let task = Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await engine.translate(text, context: context))
            } catch {
                result = .failure(error)
            }
            await self?.completeTranslation(
                result,
                segmentID: segmentID,
                token: token
            )
        }
        translationTasks[segmentID] = PendingTranslation(token: token, task: task)
    }

    private func completeTranslation(
        _ result: Result<String, Error>,
        segmentID: UUID,
        token: UUID
    ) {
        guard translationTasks[segmentID]?.token == token else { return }
        translationTasks[segmentID] = nil

        if case let .success(translation) = result,
           !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyTranslation(translation, to: segmentID)
            publish()
        }
    }

    private func cancelPendingTranslations() {
        for pending in translationTasks.values {
            pending.task.cancel()
        }
        translationTasks.removeAll()
    }

    private func makeSnapshot() -> TranscriptSnapshot {
        TranscriptSnapshot(
            finalSegments: finalSegments,
            provisionalSegment: provisionalSegment
        )
    }

    private func publish() {
        let snapshot = makeSnapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private static func transcriptChunks(
        _ text: String,
        maximumWordsPerSegment: Int
    ) -> [String] {
        let maximumWordsPerSegment = max(1, maximumWordsPerSegment)
        var sentences: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: .bySentences
        ) { substring, _, _, _ in
            guard let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sentence.isEmpty else { return }
            sentences.append(sentence)
        }
        if sentences.isEmpty {
            sentences = [text]
        }

        var chunks: [String] = []
        var currentSentences: [String] = []
        var currentWordCount = 0

        func flushCurrentChunk() {
            guard !currentSentences.isEmpty else { return }
            chunks.append(currentSentences.joined(separator: " "))
            currentSentences.removeAll(keepingCapacity: true)
            currentWordCount = 0
        }

        for sentence in sentences {
            let words = sentence.split(whereSeparator: \.isWhitespace)
            if words.count > maximumWordsPerSegment {
                flushCurrentChunk()
                var start = words.startIndex
                while start < words.endIndex {
                    let end = words.index(
                        start,
                        offsetBy: maximumWordsPerSegment,
                        limitedBy: words.endIndex
                    ) ?? words.endIndex
                    chunks.append(words[start..<end].joined(separator: " "))
                    start = end
                }
            } else {
                if currentWordCount + words.count > maximumWordsPerSegment {
                    flushCurrentChunk()
                }
                currentSentences.append(sentence)
                currentWordCount += words.count
            }
        }
        flushCurrentChunk()
        return chunks
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

private struct PendingTranslation {
    var token: UUID
    var task: Task<Void, Never>
}
