import ClassBridgeCore
import SwiftUI

struct ClassroomWorkspaceView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            sessionToolbar
            Divider()
            statusBar
            Divider()
            transcriptSurface
            Divider()
            markerBar
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sessionToolbar: some View {
        HStack(spacing: 12) {
            TextField("课程名称", text: $model.courseName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260, idealWidth: 360, maxWidth: 440)
                .disabled(model.isActive)

            Picker("场景", selection: $model.sessionKind) {
                Text("课堂").tag(SessionKind.lecture)
                Text("会议").tag(SessionKind.meeting)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .disabled(model.isActive)

            Picker("模式", selection: $model.processingMode) {
                Text("本地").tag(ProcessingMode.local)
                Text("高精度").tag(ProcessingMode.highAccuracy)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .disabled(model.isActive)

            Spacer(minLength: 12)

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
                Button(action: model.startSession) {
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

    private var transcriptSurface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.snapshot.finalSegments.isEmpty,
                       model.snapshot.provisionalSegment == nil {
                        ContentUnavailableView(
                            "等待课堂字幕",
                            systemImage: "captions.bubble",
                            description: Text("输入课程名称后开始")
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                    }

                    ForEach(Array(model.snapshot.finalSegments.enumerated()), id: \.element.id) { index, segment in
                        SubtitleRow(
                            segment: segment,
                            isCurrent: index == model.snapshot.finalSegments.count - 1
                        )
                        .id(segment.id)
                    }

                    if let provisional = model.snapshot.provisionalSegment {
                        ProvisionalSubtitleRow(segment: provisional)
                            .id("provisional")
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            .onChange(of: model.snapshot.finalSegments.count) {
                if let id = model.snapshot.finalSegments.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
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
            .disabled(!model.isActive)

            Spacer()

            Picker("音频", selection: $model.audioSource) {
                Label("麦克风", systemImage: "mic").tag(AudioSource.microphone)
                Label("系统音频", systemImage: "speaker.wave.2").tag(AudioSource.systemAudio)
                Label("混合", systemImage: "waveform").tag(AudioSource.mixed)
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(model.isActive)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusIcon: String {
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
