import Foundation

public actor SubtitlePipeline {
    private let course: Course
    private let translationEngine: any TranslationEngine
    private let approvedTerms: [GlossaryTerm]
    private let recentContextLimit: Int

    private var finalSegments: [TranscriptSegment] = []
    private var provisionalSegment: TranscriptSegment?
    private var continuations: [UUID: AsyncStream<TranscriptSnapshot>.Continuation] = [:]

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

            let segment = TranscriptSegment(
                id: id,
                startTime: startTime,
                endTime: endTime,
                sourceText: text,
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

            do {
                let translation = try await translationEngine.translate(text, context: context)
                applyTranslation(translation, to: id)
                publish()
            } catch {
                // Keep the finalized English segment. Translation can be retried later.
            }

        case .failed:
            provisionalSegment = nil
            publish()

        case .finished:
            provisionalSegment = nil
            publish()
        }
    }

    public func reset() {
        finalSegments.removeAll()
        provisionalSegment = nil
        publish()
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
}
