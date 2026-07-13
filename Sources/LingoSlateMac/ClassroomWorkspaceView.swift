import LingoSlateCore
import SwiftUI
import Translation

struct ClassroomWorkspaceView: View {
    private enum FocusedField: Hashable {
        case courseName
        case courseTerms
    }

    private struct TranscriptScrollKey: Equatable {
        var finalCount: Int
        var latestSourceLength: Int
        var latestTranslationLength: Int
        var provisionalID: UUID?
        var provisionalLength: Int
    }

    @Environment(\.openSettings) private var openSettings
    @StateObject private var model: AppModel
    @State private var completedSurface: CompletedSurface = .summary
    @FocusState private var focusedField: FocusedField?
    private let transcriptBottomID = "transcript-bottom"

    init(profileStore: UserProfileStore) {
        _model = StateObject(
            wrappedValue: AppModel(profileStore: profileStore)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionToolbar
            Divider()
            courseContextBar
            Divider()
            statusBar
            Divider()
            transcriptSurface
            Divider()
            markerBar
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            AppleTranslationSessionHost(engine: model.translationEngine)
        }
        .onChange(of: model.lifecycleState) { _, state in
            if state != .idle {
                focusedField = nil
            }
            if state == .completed {
                completedSurface = .summary
            }
        }
        .onChange(of: model.isWarmingUp) { _, isWarmingUp in
            if isWarmingUp {
                focusedField = nil
            }
        }
    }

    private var courseContextBar: some View {
        HStack(spacing: 10) {
            Label("课程术语", systemImage: "text.book.closed")
                .foregroundStyle(.secondary)

            TextField("Waikato, MyWaikato, Panopto", text: $model.courseTermsText)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .courseTerms)
                .disabled(model.isActive || model.isWarmingUp)

            if let diagnostics = model.warmupDiagnostics,
               model.isCourseWarm || diagnostics.prewarmedRecognitionReused == true {
                Label("\(diagnostics.terms.count) 个术语", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(warmupDetails(diagnostics))
            }
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sessionToolbar: some View {
        HStack(spacing: 12) {
            TextField("课程名称（可选）", text: $model.courseName)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .courseName)
                .frame(minWidth: 260, idealWidth: 360, maxWidth: 440)
                .disabled(model.isActive || model.isWarmingUp)

            Picker("场景", selection: $model.sessionKind) {
                Text("课堂").tag(SessionKind.lecture)
                Text("会议").tag(SessionKind.meeting)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .disabled(model.isActive || model.isWarmingUp)

            Picker("模式", selection: $model.processingMode) {
                Text("省电").tag(ProcessingMode.local)
                Text("高精度").tag(ProcessingMode.highAccuracy)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .disabled(model.isActive || model.isWarmingUp)
            .help("高精度适合课堂和会议；省电适合近距离清晰语音")

            Spacer(minLength: 12)

            Button(action: { openSettings() }) {
                Image(systemName: "person.crop.circle")
            }
            .help("用户资料")

            if model.isWarmingUp {
                Button(action: model.cancelWarmup) {
                    Image(systemName: "xmark.circle")
                }
                .help("取消预热")
            } else if !model.isActive, model.lifecycleState != .completed {
                Button(action: {
                    focusedField = nil
                    model.warmUpCourse()
                }) {
                    Image(systemName: model.isCourseWarm ? "bolt.fill" : "bolt")
                }
                .help(model.isCourseWarm ? "课程已预热" : "预热课程")
                .disabled(!model.canWarmUp)
            }

            if model.isActive {
                Button(role: .destructive, action: model.stopSession) {
                    Label("结束", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(".", modifiers: [.command])
            } else if model.lifecycleState == .completed {
                Button(action: model.resetForNextSession) {
                    Label("新课堂", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: {
                    focusedField = nil
                    model.startSession()
                }) {
                    Label("开始", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var statusBar: some View {
        HStack(spacing: 18) {
            Label(model.statusMessage, systemImage: statusIcon)
                .foregroundStyle(statusColor)

            Label(audioSourceLabel, systemImage: "mic.fill")
                .foregroundStyle(.secondary)

            TranslationStatusLabel(
                engine: model.translationEngine,
                isEnhanced: model.isEnhancedTranslationReady
                    && model.processingMode == .highAccuracy
            )

            if model.isActive, model.audioSource == .microphone {
                ProgressView(value: Double(model.inputLevel))
                    .progressViewStyle(.linear)
                    .frame(width: 72)
                    .accessibilityLabel("麦克风输入电平")

                if let sampleRate = model.captureSampleRate {
                    Text("\(Int(sampleRate / 1_000)) kHz")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if model.isInputLevelLow {
                    Label("收音偏弱", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("连续收音偏弱，建议将 Mac 或 iPhone 麦克风靠近讲者")
                }
            }

            if let startedAt = model.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(
                        durationText(context.date.timeIntervalSince(startedAt)),
                        systemImage: "clock"
                    )
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !model.markers.isEmpty {
                Label("\(model.markers.count)", systemImage: "bookmark.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var transcriptSurface: some View {
        if model.lifecycleState == .completed {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("课后内容", selection: $completedSurface) {
                        Text("摘要").tag(CompletedSurface.summary)
                        Text("全文").tag(CompletedSurface.transcript)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)

                    if model.savedAudioURL != nil {
                        Button(action: model.playSavedAudio) {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 28, height: 28)
                        .help("播放本地录音")

                        Button(action: model.revealSavedAudio) {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 28, height: 28)
                        .help("在 Finder 中显示录音")
                    }
                }
                .padding(.vertical, 10)

                Divider()

                switch completedSurface {
                case .summary:
                    SessionSummaryView(summary: model.summary)
                case .transcript:
                    transcriptScrollView
                }
            }
        } else {
            transcriptScrollView
        }
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.snapshot.finalSegments.isEmpty,
                       model.snapshot.provisionalSegment == nil {
                        ContentUnavailableView(
                            "等待课堂字幕",
                            systemImage: "captions.bubble",
                            description: Text("可直接开始，课程名称用于增强术语识别")
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                    }

                    ForEach(model.snapshot.finalSegments) { segment in
                        SubtitleRow(
                            segment: segment,
                            isCurrent: segment.id == model.snapshot.finalSegments.last?.id
                        )
                        .id(segment.id)
                    }

                    if let provisional = model.snapshot.provisionalSegment {
                        ProvisionalSubtitleRow(segment: provisional)
                            .id("provisional")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(transcriptBottomID)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            .onChange(of: transcriptScrollKey) {
                guard model.isActive else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var markerBar: some View {
        HStack(spacing: 8) {
            Group {
                MarkerButton(
                    title: "书签",
                    systemImage: "bookmark",
                    action: { model.addMarker(.bookmark) }
                )
                MarkerButton(
                    title: "重点",
                    systemImage: "star",
                    action: { model.addMarker(.important) }
                )
                MarkerButton(
                    title: "问题",
                    systemImage: "questionmark.circle",
                    action: { model.addMarker(.question) }
                )
                MarkerButton(
                    title: "任务",
                    systemImage: "checkmark.circle",
                    action: { model.addMarker(.actionItem) }
                )
            }
            .disabled(!model.canAddMarker)

            Spacer()

            Picker("音频", selection: $model.audioSource) {
                Label("麦克风", systemImage: "mic").tag(AudioSource.microphone)
                Label("系统音频", systemImage: "speaker.wave.2")
                    .tag(AudioSource.systemAudio)
                    .disabled(true)
                Label("混合", systemImage: "waveform")
                    .tag(AudioSource.mixed)
                    .disabled(true)
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(model.isActive)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var transcriptScrollKey: TranscriptScrollKey {
        let latest = model.snapshot.finalSegments.last
        let provisional = model.snapshot.provisionalSegment
        return TranscriptScrollKey(
            finalCount: model.snapshot.finalSegments.count,
            latestSourceLength: latest?.sourceText.count ?? 0,
            latestTranslationLength: latest?.translatedText?.count ?? 0,
            provisionalID: provisional?.id,
            provisionalLength: provisional?.sourceText.count ?? 0
        )
    }

    private var statusIcon: String {
        if model.isWarmingUp {
            return "bolt.horizontal.circle"
        }
        switch model.lifecycleState {
        case .running:
            return "waveform"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .preparing, .finalizing:
            return "clock.arrow.circlepath"
        default:
            return "circle"
        }
    }

    private var statusColor: Color {
        switch model.lifecycleState {
        case .running:
            return .green
        case .failed:
            return .red
        case .completed:
            return .blue
        default:
            return .secondary
        }
    }

    private var audioSourceLabel: String {
        switch model.audioSource {
        case .microphone:
            return "麦克风"
        case .systemAudio:
            return "系统音频"
        case .mixed:
            return "混合音频"
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }

    private func warmupDetails(_ diagnostics: SessionPreparationDiagnostics) -> String {
        let asr = diagnostics.asrModelReady ? "已就绪" : "未就绪"
        let quickTranslation = diagnostics.quickTranslationReady ? "已就绪" : "未就绪"
        let enhancedTranslation = diagnostics.enhancedTranslationReady ? "已就绪" : "未就绪"
        let reuse: String
        switch diagnostics.prewarmedRecognitionReused {
        case true:
            reuse = "已复用"
        case false:
            reuse = "未复用"
        case nil:
            reuse = "等待开课验证"
        }
        return "转写：\(asr)\n快速翻译：\(quickTranslation)\n高质量精译：\(enhancedTranslation)\n"
            + "生成术语：\(diagnostics.generatedTermCount) 个\n预热引擎：\(reuse)\n\n"
            + diagnostics.terms.joined(separator: ", ")
    }
}

private enum CompletedSurface: Hashable {
    case summary
    case transcript
}

struct SessionSummaryView: View {
    let summary: SessionSummary?

    var body: some View {
        if let summary, !summary.isEmpty {
            ScrollView {
                SummaryContentView(summary: summary)
            }
        } else {
            ContentUnavailableView(
                "暂无可总结内容",
                systemImage: "doc.text.magnifyingglass",
                description: Text("本次课堂没有识别到稳定字幕")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SummaryContentView: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SummarySection(
                title: "课堂概览",
                systemImage: "text.alignleft",
                items: summary.overview
            )
            SummarySection(
                title: "核心概念",
                systemImage: "lightbulb",
                items: summary.keyConcepts
            )
            SummarySection(
                title: "任务与提醒",
                systemImage: "checklist",
                items: summary.actionItems
            )
        }
        .frame(maxWidth: 920, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct SummarySection: View {
    let title: String
    let systemImage: String
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.tertiary)
                            Text(item)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }
}

private struct AppleTranslationSessionHost: View {
    @ObservedObject var engine: AppleTranslationEngine

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .translationTask(engine.configuration) { session in
                await engine.run(systemSession: session)
            }
    }
}

private struct TranslationStatusLabel: View {
    @ObservedObject var engine: AppleTranslationEngine
    let isEnhanced: Bool

    var body: some View {
        Label(statusLabel, systemImage: isEnhanced ? "sparkles" : engine.statusIcon)
            .foregroundStyle(statusColor)
            .help(failureMessage ?? statusLabel)
    }

    private var statusLabel: String {
        isEnhanced ? "本地精译" : engine.statusLabel
    }

    private var statusColor: Color {
        switch engine.state {
        case .ready:
            return .green
        case .failed:
            return .orange
        case .idle, .preparing:
            return .secondary
        }
    }

    private var failureMessage: String? {
        guard case let .failed(message) = engine.state else { return nil }
        return message
    }
}

private struct SubtitleRow: View {
    let segment: TranscriptSegment
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(timestamp(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    Text(segment.sourceText)
                        .font(.system(size: 22, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .textSelection(.enabled)

                    if let translatedText = segment.translatedText {
                        Text(translatedText)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .padding(.leading, 64)
        }
        .padding(.vertical, 14)
    }

    private func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ProvisionalSubtitleRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(.orange)
                .frame(width: 52, alignment: .leading)

            Text(segment.sourceText)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18)
    }
}

private struct MarkerButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .help(title)
    }
}
