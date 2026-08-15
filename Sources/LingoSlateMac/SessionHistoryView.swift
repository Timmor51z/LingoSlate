import AppKit
import LingoSlateCore
import SwiftUI

private enum SessionHistorySurface: Hashable {
    case summary
    case transcript
}

struct SessionHistoryView: View {
    let directoryURL: URL
    private let store: SessionStore

    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [SessionDocument] = []
    @State private var selectedID: UUID?
    @State private var searchText = ""
    @State private var surface: SessionHistorySurface = .summary
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var pendingDeletion: SessionDocument?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        store = SessionStore(directoryURL: directoryURL)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("搜索课程、讲师或字幕", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)

                Divider()

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredSessions.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "暂无课堂记录" : "没有匹配记录",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    List(filteredSessions, selection: $selectedID) { session in
                        SessionHistoryRow(session: session)
                            .tag(session.id)
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 380)
        } detail: {
            if let selectedSession {
                SessionHistoryDetail(
                    session: selectedSession,
                    directoryURL: directoryURL,
                    surface: $surface,
                    onDelete: { pendingDeletion = selectedSession }
                )
                .id(selectedSession.id)
            } else {
                ContentUnavailableView(
                    "选择一节课堂",
                    systemImage: "text.book.closed"
                )
            }
        }
        .navigationTitle("课堂记录")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                }
                .help("关闭课堂记录")
                .keyboardShortcut(.cancelAction)
            }

            ToolbarItemGroup {
                Button(action: revealSessionFolder) {
                    Image(systemName: "folder")
                }
                .help("打开记录文件夹")

                Button {
                    Task { await loadSessions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .task { await loadSessions() }
        .onChange(of: searchText) { _, _ in
            selectFirstVisibleSession()
        }
        .alert(
            "删除这节课堂？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { session in
            Button("删除记录和录音", role: .destructive) {
                Task { await delete(session) }
            }
            Button("取消", role: .cancel) {}
        } message: { session in
            Text("“\(sessionTitle(session))”将从本机永久删除。")
        }
        .alert(
            "无法读取课堂记录",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好") {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var filteredSessions: [SessionDocument] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            let course = session.configuration.course
            return course.name.lowercased().contains(query)
                || course.lecturerNames.contains { $0.lowercased().contains(query) }
                || session.segments.contains {
                    $0.sourceText.lowercased().contains(query)
                        || $0.translatedText?.lowercased().contains(query) == true
                }
        }
    }

    private var selectedSession: SessionDocument? {
        sessions.first { $0.id == selectedID }
    }

    @MainActor
    private func loadSessions() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await store.list()
            selectFirstVisibleSession()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ session: SessionDocument) async {
        pendingDeletion = nil
        do {
            try await store.delete(id: session.id)
            sessions.removeAll { $0.id == session.id }
            selectFirstVisibleSession()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revealSessionFolder() {
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(directoryURL)
    }

    private func selectFirstVisibleSession() {
        let visibleSessions = filteredSessions
        if !visibleSessions.contains(where: { $0.id == selectedID }) {
            selectedID = visibleSessions.first?.id
        }
    }
}

private struct SessionHistoryRow: View {
    let session: SessionDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(sessionTitle(session))
                    .font(.headline)
                    .lineLimit(1)
                if session.failureMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(session.failureMessage ?? "课堂未完整结束")
                }
            }
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(session.segments.count) 段字幕 · \(sessionDuration(session))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct SessionHistoryDetail: View {
    let session: SessionDocument
    let directoryURL: URL
    @Binding var surface: SessionHistorySurface
    let onDelete: () -> Void
    @State private var isExporting = false
    @State private var exportAlert: SessionExportAlert?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sessionTitle(session))
                            .font(.title2.weight(.semibold))
                        Text(metadata)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: exportPracticePackage) {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .frame(width: 20, height: 20)
                    .disabled(isExporting)
                    .help("导出听力练习包")
                    if let audioURL {
                        Button(action: { NSWorkspace.shared.open(audioURL) }) {
                            Image(systemName: "play.circle")
                        }
                        .help("播放录音")
                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([audioURL]) }) {
                            Image(systemName: "folder")
                        }
                        .help("在 Finder 中显示录音")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .help("删除课堂记录")
                }

                if let failureMessage = session.failureMessage {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Picker("内容", selection: $surface) {
                    Text("摘要").tag(SessionHistorySurface.summary)
                    Text("双语全文").tag(SessionHistorySurface.transcript)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            .padding(20)

            Divider()

            switch surface {
            case .summary:
                SessionSummaryView(summary: session.summary)
            case .transcript:
                historyTranscript
            }
        }
        .alert(item: $exportAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private func exportPracticePackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出到这里"
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isExporting = true
        let session = session
        let directoryURL = directoryURL
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SessionPracticeExporter.export(
                        session: session,
                        sessionDirectoryURL: directoryURL,
                        destinationDirectoryURL: destinationURL
                    )
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([result.directoryURL])
                if result.audioURL == nil {
                    exportAlert = SessionExportAlert(
                        title: "字幕已导出",
                        message: "未找到这节课堂的录音文件，练习包中仅包含英文和双语字幕。"
                    )
                }
            } catch {
                exportAlert = SessionExportAlert(
                    title: "无法导出",
                    message: error.localizedDescription
                )
            }
            isExporting = false
        }
    }

    private var historyTranscript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if session.segments.isEmpty {
                    ContentUnavailableView(
                        "暂无字幕",
                        systemImage: "captions.bubble"
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    ForEach(session.segments) { segment in
                        HistoryTranscriptRow(segment: segment)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
    }

    private var audioURL: URL? {
        guard let name = session.audioFileName,
              URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
        let url = directoryURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var metadata: String {
        var values = [
            session.startedAt.formatted(date: .long, time: .shortened),
            sessionDuration(session),
            processingModeLabel,
        ]
        values.append(contentsOf: session.configuration.course.lecturerNames)
        if session.configuration.processingMode == .highAccuracy {
            let eligible = session.segments.filter {
                $0.translationExclusionReason == nil
            }
            let attributed = eligible.filter { $0.translationProvider != nil }
            if attributed.isEmpty, !eligible.isEmpty {
                values.append("精译来源未记录")
            } else {
                let refined = attributed.filter {
                    $0.translationProvider == "translategemma-4b"
                }.count
                values.append("本地精译 \(refined)/\(eligible.count)")
            }
        }
        return values.joined(separator: " · ")
    }

    private var processingModeLabel: String {
        switch session.configuration.processingMode {
        case .local:
            return "省电"
        case .highAccuracy:
            return "高精度"
        case .soniox:
            return "Soniox"
        }
    }
}

private struct SessionExportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct HistoryTranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(timestamp(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(segment.sourceText)
                    .font(.body)
                    .textSelection(.enabled)
                if let translated = segment.translatedText, !translated.isEmpty {
                    Text(translated)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if segment.translationExclusionReason != nil {
                    Label("中文讨论，已跳过翻译", systemImage: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private func sessionTitle(_ session: SessionDocument) -> String {
    let name = session.configuration.course.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty
        ? (session.configuration.kind == .lecture ? "未命名课堂" : "未命名会议")
        : name
}

private func sessionDuration(_ session: SessionDocument) -> String {
    let duration = session.endedAt.map { $0.timeIntervalSince(session.startedAt) }
        ?? session.segments.map(\.endTime).max()
        ?? 0
    let seconds = max(0, Int(duration))
    if seconds >= 3_600 {
        return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
