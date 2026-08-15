import Foundation

public actor SubtitlePipeline {
    private static let chineseTranslationExclusion = "detectedChineseDiscussion"
    private let course: Course
    private let translationEngine: any TranslationEngine
    private let approvedTerms: [GlossaryTerm]
    private let recentContextLimit: Int
    private let maximumPendingTranslations: Int
    private let termNormalizer: TranscriptTermNormalizer

    private var finalSegments: [TranscriptSegment] = []
    private var provisionalSegment: TranscriptSegment?
    private var continuations: [UUID: AsyncStream<TranscriptSnapshot>.Continuation] = [:]
    private var translationTasks: [UUID: PendingTranslation] = [:]
    private var deferredTranslations: [UUID: DeferredTranslation] = [:]
    private var contextualFollowups: [UUID: DeferredTranslation] = [:]
    private var replacementProgress: (@Sendable (Int, Int) -> Void)?
    private var replacementSegmentIDs: Set<UUID> = []
    private var completedReplacementSegmentIDs: Set<UUID> = []
    private var translationPhase: TranslationPhase = .live
    private var learnedCorrections: [String: String] = [:]

    public init(
        course: Course,
        translationEngine: any TranslationEngine,
        approvedTerms: [GlossaryTerm] = [],
        recognitionCorrections: [GlossaryTerm] = [],
        recentContextLimit: Int = 4,
        maximumPendingTranslations: Int = 12
    ) {
        self.course = course
        self.translationEngine = translationEngine
        self.approvedTerms = approvedTerms.filter(\.isApproved)
        self.recentContextLimit = max(0, recentContextLimit)
        self.maximumPendingTranslations = max(1, maximumPendingTranslations)
        self.termNormalizer = TranscriptTermNormalizer(
            course: course,
            approvedTerms: self.approvedTerms + recognitionCorrections
        )
    }

    public func snapshots() -> AsyncStream<TranscriptSnapshot> {
        let subscriptionID = UUID()
        let initialSnapshot = makeSnapshot()

        let pair = AsyncStream<TranscriptSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
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
            let normalizedText = normalizeSourceText(text)
            provisionalSegment = TranscriptSegment(
                id: id,
                startTime: startTime,
                endTime: endTime,
                sourceText: normalizedText,
                state: .provisional,
                provider: provider
            )
            publish()

        case let .final(id, text, startTime, endTime, speaker, provider):
            let normalizedText = normalizeSourceText(text)
            consumeFinalSegment(
                TranscriptSegment(
                    id: id,
                    startTime: startTime,
                    endTime: endTime,
                    sourceText: normalizedText,
                    speaker: speaker,
                    state: .final,
                    provider: provider
                ),
                shouldScheduleLocalTranslation: true
            )

        case let .bilingualProvisional(result):
            let normalizedText = normalizeSourceText(result.sourceText)
            let excludesTranslation = Self.isExcludedFromTranslation(
                normalizedText,
                sourceLanguage: result.sourceLanguage
            )
            let translatedText = excludesTranslation
                ? nil
                : result.translatedText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfBlank
            provisionalSegment = TranscriptSegment(
                id: result.id,
                startTime: result.startTime,
                endTime: result.endTime,
                sourceText: normalizedText,
                translatedText: translatedText,
                speaker: result.speaker,
                state: .provisional,
                provider: result.recognitionProvider,
                translationProvider: translatedText == nil
                    ? nil
                    : result.translationProvider,
                translationExclusionReason: excludesTranslation
                    ? Self.chineseTranslationExclusion
                    : nil,
                sourceLanguage: result.sourceLanguage
            )
            publish()

        case let .bilingualFinal(result):
            let normalizedText = normalizeSourceText(result.sourceText)
            let translatedText = result.translatedText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank
            consumeFinalSegment(
                TranscriptSegment(
                    id: result.id,
                    startTime: result.startTime,
                    endTime: result.endTime,
                    sourceText: normalizedText,
                    translatedText: translatedText,
                    speaker: result.speaker,
                    state: translatedText == nil ? .final : .translated,
                    provider: result.recognitionProvider,
                    translationProvider: translatedText == nil
                        ? nil
                        : result.translationProvider,
                    sourceLanguage: result.sourceLanguage
                ),
                shouldScheduleLocalTranslation: translatedText == nil
            )

        case .failed:
            provisionalSegment = nil
            publish()

        case .finished:
            provisionalSegment = nil
            publish()
        }
    }

    private func consumeFinalSegment(
        _ incomingSegment: TranscriptSegment,
        shouldScheduleLocalTranslation: Bool
    ) {
        translationPhase = .live
        provisionalSegment = nil
        var segment = incomingSegment
        markTranslationEligibility(&segment)
        upsertFinalSegment(segment)
        publish()

        let eligibleIndices = finalSegments.indices.filter {
            finalSegments[$0].translationExclusionReason == nil
        }
        let shouldContextuallyRetranslate = eligibleIndices.count >= 3
            && eligibleIndices.count.isMultiple(of: 3)
            && shouldRefine(context: contextualTranslationContext(
                for: eligibleIndices.last ?? finalSegments.startIndex
            ))
        if shouldContextuallyRetranslate {
            for index in eligibleIndices.suffix(3) {
                let contextualSegment = finalSegments[index]
                scheduleContextualRetranslation(
                    text: contextualSegment.sourceText,
                    segmentID: contextualSegment.id,
                    context: contextualTranslationContext(for: index)
                )
            }
        } else if segment.translationExclusionReason == nil,
                  shouldScheduleLocalTranslation {
            scheduleTranslation(
                text: segment.sourceText,
                segmentID: segment.id,
                context: translationContext(
                    before: finalSegments.firstIndex(where: { $0.id == segment.id })
                        ?? finalSegments.endIndex,
                    phase: .live
                )
            )
        }
    }

    public func reset() {
        cancelPendingTranslations()
        finalSegments.removeAll()
        provisionalSegment = nil
        translationPhase = .live
        learnedCorrections.removeAll()
        publish()
    }

    @discardableResult
    public func finishPendingTranslations(
        timeout: Duration = .seconds(45)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !translationTasks.isEmpty
                || !deferredTranslations.isEmpty
                || !contextualFollowups.isEmpty {
            guard !Task.isCancelled, clock.now < deadline else {
                cancelPendingTranslations()
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    public func retranslateMissing() {
        for (index, segment) in finalSegments.enumerated()
        where segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            guard segment.translationExclusionReason == nil,
                  translationTasks[segment.id] == nil,
                  deferredTranslations[segment.id] == nil else { continue }
            scheduleTranslation(
                text: segment.sourceText,
                segmentID: segment.id,
                context: translationContext(before: index)
            )
        }
    }

    public func correctSegment(id: UUID, sourceText: String) {
        let sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty,
              let index = finalSegments.firstIndex(where: { $0.id == id }) else { return }
        let originalSourceText = finalSegments[index].sourceText
        translationTasks[id]?.task.cancel()
        translationTasks[id] = nil
        deferredTranslations[id] = nil
        contextualFollowups[id] = nil
        finalSegments[index].sourceText = sourceText
        finalSegments[index].translatedText = nil
        finalSegments[index].state = .final
        finalSegments[index].isUserCorrected = true
        finalSegments[index].translationProvider = nil
        finalSegments[index].translationFailureReason = nil
        finalSegments[index].sourceLanguage = nil
        markTranslationEligibility(&finalSegments[index])
        learnedCorrections[originalSourceText.lowercased()] = sourceText
        publish()
        guard finalSegments[index].translationExclusionReason == nil else { return }
        scheduleTranslation(
            text: sourceText,
            segmentID: id,
            context: translationContext(before: index, phase: .contextualLive)
        )
    }

    @discardableResult
    public func replaceFinalTranscript(
        with text: String,
        duration: TimeInterval,
        provider: String,
        maximumWordsPerSegment: Int = 36,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> Bool {
        let text = normalizeSourceText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let chunks = Self.transcriptChunks(
            text,
            maximumWordsPerSegment: maximumWordsPerSegment
        )
        guard !chunks.isEmpty else { return false }

        let wordCounts = chunks.map(Self.wordCount)
        let totalWordCount = max(1, wordCounts.reduce(0, +))
        var elapsedWordCount = 0

        let replacements = chunks.enumerated().map { index, chunk in
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
        return await replaceFinalTranscript(
            with: replacements,
            progress: progress
        )
    }

    @discardableResult
    public func replaceFinalTranscript(
        with timedChunks: [TimedTranscriptChunk],
        provider: String,
        maximumWordsPerSegment: Int = 36,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> Bool {
        let replacements = timedChunks.flatMap { timedChunk -> [TranscriptSegment] in
            let text = normalizeSourceText(timedChunk.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let chunks = Self.transcriptChunks(
                text,
                maximumWordsPerSegment: maximumWordsPerSegment
            )
            let wordCounts = chunks.map(Self.wordCount)
            let totalWordCount = max(1, wordCounts.reduce(0, +))
            let duration = max(0, timedChunk.endTime - timedChunk.startTime)
            var elapsedWordCount = 0
            return chunks.enumerated().map { index, chunk in
                let startTime = timedChunk.startTime
                    + duration * Double(elapsedWordCount) / Double(totalWordCount)
                elapsedWordCount += wordCounts[index]
                let endTime = index == chunks.indices.last
                    ? timedChunk.endTime
                    : timedChunk.startTime
                        + duration * Double(elapsedWordCount) / Double(totalWordCount)
                return TranscriptSegment(
                    startTime: startTime,
                    endTime: max(startTime, endTime),
                    sourceText: chunk,
                    state: .final,
                    provider: provider
                )
            }
        }.sorted { $0.startTime < $1.startTime }

        return await replaceFinalTranscript(
            with: replacements,
            progress: progress
        )
    }

    private func replaceFinalTranscript(
        with replacements: [TranscriptSegment],
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async -> Bool {
        cancelPendingTranslations()
        let originalFinalSegments = finalSegments
        let originalTranslationPhase = translationPhase
        guard !replacements.isEmpty,
              !finalSegments.contains(where: \.isUserCorrected) else {
            return false
        }

        finalSegments = replacements.map { segment in
            var segment = segment
            markTranslationEligibility(&segment)
            return segment
        }
        translationPhase = .postClass
        provisionalSegment = nil
        publish()
        replacementProgress = progress
        replacementSegmentIDs = Set(
            finalSegments
                .filter { $0.translationExclusionReason == nil }
                .map(\.id)
        )
        completedReplacementSegmentIDs.removeAll(keepingCapacity: true)
        progress?(0, replacementSegmentIDs.count)

        for index in finalSegments.indices {
            guard !Task.isCancelled else {
                restoreFinalSegments(
                    originalFinalSegments,
                    phase: originalTranslationPhase
                )
                return false
            }
            let segment = finalSegments[index]
            guard segment.translationExclusionReason == nil else { continue }
            scheduleTranslation(
                text: segment.sourceText,
                segmentID: segment.id,
                context: translationContext(before: index, phase: .postClass)
            )
        }
        let timeoutSeconds = min(20 * 60, max(45, replacementSegmentIDs.count * 3))
        let completed = await finishPendingTranslations(
            timeout: .seconds(timeoutSeconds)
        )
        guard !Task.isCancelled else {
            restoreFinalSegments(
                originalFinalSegments,
                phase: originalTranslationPhase
            )
            return false
        }
        clearReplacementProgress()
        return completed
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
        translationTasks[segmentID] = nil
        deferredTranslations[segmentID] = nil
        contextualFollowups[segmentID] = nil
        let request = DeferredTranslation(text: text, context: context)
        guard translationTasks.count < maximumPendingTranslations else {
            deferredTranslations[segmentID] = request
            return
        }
        startTranslation(request, segmentID: segmentID)
    }

    private func scheduleContextualRetranslation(
        text: String,
        segmentID: UUID,
        context: TranslationContext
    ) {
        let request = DeferredTranslation(text: text, context: context)
        if translationTasks[segmentID] != nil || deferredTranslations[segmentID] != nil {
            contextualFollowups[segmentID] = request
            return
        }
        scheduleTranslation(text: text, segmentID: segmentID, context: context)
    }

    private func startTranslation(
        _ request: DeferredTranslation,
        segmentID: UUID
    ) {
        let token = UUID()
        let engine = translationEngine
        let text = request.text
        let context = request.context
        let stagedEngine = engine as? StagedTranslationEngine
        let primaryIdentifier = stagedEngine?.primaryIdentifier ?? engine.identifier
        let refinementIdentifier = stagedEngine?.refinementIdentifier ?? engine.identifier
        let task = Task { [weak self] in
            do {
                let translation = try await engine.translate(text, context: context)
                await self?.publishTranslation(
                    translation,
                    segmentID: segmentID,
                    token: token,
                    provider: primaryIdentifier
                )
            } catch {
                await self?.recordTranslationFailure(
                    error.localizedDescription,
                    segmentID: segmentID,
                    token: token
                )
                if let refiner = engine as? any TranslationRefinementEngine,
                   refiner.shouldRefine(context: context) {
                    do {
                        let refined = try await refiner.refine(text, context: context)
                        await self?.publishTranslation(
                            refined,
                            segmentID: segmentID,
                            token: token,
                            provider: refinementIdentifier
                        )
                    } catch {
                        await self?.recordTranslationFailure(
                            error.localizedDescription,
                            segmentID: segmentID,
                            token: token
                        )
                    }
                }
                await self?.finishTranslation(segmentID: segmentID, token: token)
                return
            }

            if let refiner = engine as? any TranslationRefinementEngine,
               refiner.shouldRefine(context: context) {
                do {
                    let refined = try await refiner.refine(text, context: context)
                    await self?.publishTranslation(
                        refined,
                        segmentID: segmentID,
                        token: token,
                        provider: refinementIdentifier
                    )
                } catch {
                    await self?.recordTranslationFailure(
                        error.localizedDescription,
                        segmentID: segmentID,
                        token: token
                    )
                }
            }
            await self?.finishTranslation(segmentID: segmentID, token: token)
        }
        translationTasks[segmentID] = PendingTranslation(token: token, task: task)
    }

    private func publishTranslation(
        _ translation: String,
        segmentID: UUID,
        token: UUID,
        provider: String
    ) {
        guard translationTasks[segmentID]?.token == token else { return }
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        applyTranslation(translation, to: segmentID)
        if let index = finalSegments.firstIndex(where: { $0.id == segmentID }) {
            finalSegments[index].translationProvider = provider
            finalSegments[index].translationFailureReason = nil
        }
        publish()
    }

    private func recordTranslationFailure(
        _ reason: String,
        segmentID: UUID,
        token: UUID
    ) {
        guard translationTasks[segmentID]?.token == token,
              let index = finalSegments.firstIndex(where: { $0.id == segmentID }) else {
            return
        }
        finalSegments[index].translationFailureReason = reason
        publish()
    }

    private func finishTranslation(segmentID: UUID, token: UUID) {
        guard translationTasks[segmentID]?.token == token else { return }
        translationTasks[segmentID] = nil
        if replacementSegmentIDs.contains(segmentID) {
            completedReplacementSegmentIDs.insert(segmentID)
            replacementProgress?(
                completedReplacementSegmentIDs.count,
                replacementSegmentIDs.count
            )
        }
        if let followup = contextualFollowups.removeValue(forKey: segmentID) {
            startTranslation(followup, segmentID: segmentID)
            return
        }
        startNextDeferredTranslation()
    }

    private func cancelPendingTranslations() {
        for pending in translationTasks.values {
            pending.task.cancel()
        }
        translationTasks.removeAll()
        deferredTranslations.removeAll()
        contextualFollowups.removeAll()
        clearReplacementProgress()
    }

    private func startNextDeferredTranslation() {
        guard translationTasks.count < maximumPendingTranslations,
              let (segmentID, request) = deferredTranslations.first else { return }
        deferredTranslations[segmentID] = nil
        startTranslation(request, segmentID: segmentID)
    }

    private func translationContext(
        before index: Int,
        phase: TranslationPhase? = nil
    ) -> TranslationContext {
        TranslationContext(
            course: course,
            recentSourceText: Array(
                finalSegments[..<index]
                    .filter { $0.translationExclusionReason == nil }
                    .suffix(recentContextLimit)
                    .map(\.sourceText)
            ),
            approvedTerms: approvedTerms,
            phase: phase ?? translationPhase
        )
    }

    private func contextualTranslationContext(for index: Int) -> TranslationContext {
        let previousCount = (recentContextLimit + 1) / 2
        let followingCount = recentContextLimit / 2
        let previous = finalSegments[..<index]
            .filter { $0.translationExclusionReason == nil }
            .suffix(previousCount)
        let following = finalSegments.dropFirst(index + 1)
            .filter { $0.translationExclusionReason == nil }
            .prefix(followingCount)
        return TranslationContext(
            course: course,
            recentSourceText: (Array(previous) + Array(following)).map(\.sourceText),
            approvedTerms: approvedTerms,
            phase: .contextualLive
        )
    }

    private func shouldRefine(context: TranslationContext) -> Bool {
        guard let engine = translationEngine as? any TranslationRefinementEngine else {
            return false
        }
        return engine.shouldRefine(context: context)
    }

    private func normalizeSourceText(_ text: String) -> String {
        var result = termNormalizer.normalize(text)
        for (heard, corrected) in learnedCorrections {
            let pattern = "(?<![\\p{L}\\p{N}])"
                + NSRegularExpression.escapedPattern(for: heard)
                + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: corrected)
            )
        }
        return result
    }

    private func markTranslationEligibility(_ segment: inout TranscriptSegment) {
        guard Self.isExcludedFromTranslation(
            segment.sourceText,
            sourceLanguage: segment.sourceLanguage
        ) else {
            segment.translationExclusionReason = nil
            return
        }
        segment.translatedText = nil
        segment.translationProvider = nil
        segment.translationFailureReason = nil
        segment.translationExclusionReason = Self.chineseTranslationExclusion
        segment.state = .final
    }

    private static func isExcludedFromTranslation(
        _ text: String,
        sourceLanguage: String?
    ) -> Bool {
        if sourceLanguage?.lowercased().hasPrefix("zh") == true {
            return true
        }
        return isPredominantlyChinese(text)
    }

    private static func isPredominantlyChinese(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let hanCount = scalars.lazy.filter { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }.count
        guard hanCount > 0 else { return false }
        let letterCount = scalars.lazy.filter {
            CharacterSet.letters.contains($0)
        }.count
        return (hanCount >= 2 || letterCount <= 4)
            && hanCount * 5 >= max(1, letterCount)
    }

    private func restoreFinalSegments(
        _ segments: [TranscriptSegment],
        phase: TranslationPhase = .live
    ) {
        cancelPendingTranslations()
        finalSegments = segments
        translationPhase = phase
        provisionalSegment = nil
        publish()
    }

    private func clearReplacementProgress() {
        replacementProgress = nil
        replacementSegmentIDs.removeAll(keepingCapacity: false)
        completedReplacementSegmentIDs.removeAll(keepingCapacity: false)
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
            let units = wordCount(sentence) > maximumWordsPerSegment
                ? clauseChunks(sentence)
                : [sentence]
            for unit in units {
                let words = unit.split(whereSeparator: \.isWhitespace)
                guard !words.isEmpty else { continue }
                if words.count <= maximumWordsPerSegment {
                    if currentWordCount + words.count > maximumWordsPerSegment {
                        flushCurrentChunk()
                    }
                    currentSentences.append(unit)
                    currentWordCount += words.count
                    continue
                }

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
            }
        }
        flushCurrentChunk()
        return chunks
    }

    private static func clauseChunks(_ sentence: String) -> [String] {
        let delimiters: Set<Character> = [",", ";", ":", "—", "–"]
        var chunks: [String] = []
        var start = sentence.startIndex
        for index in sentence.indices where delimiters.contains(sentence[index]) {
            let end = sentence.index(after: index)
            let chunk = sentence[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            start = end
        }
        if start < sentence.endIndex {
            let chunk = sentence[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
        }
        return chunks.isEmpty ? [sentence] : chunks
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

private struct PendingTranslation {
    var token: UUID
    var task: Task<Void, Never>
}

private struct DeferredTranslation: Sendable {
    var text: String
    var context: TranslationContext
}
