#if os(iOS)
import AVFAudio
import LingoSlateCore
import SwiftUI

struct MobileSessionHistoryView: View {
    let directoryURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionDocument] = []
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "暂无课堂记录",
                        systemImage: "text.book.closed"
                    )
                } else if filteredSessions.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(filteredSessions) { session in
                            NavigationLink {
                                MobileSessionDetailView(
                                    document: session,
                                    directoryURL: directoryURL
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(sessionTitle(session))
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(session.startedAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    ))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    Text("\(session.segments.count) 条字幕")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("课堂记录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索课程或字幕")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
            .alert("无法读取课堂记录", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private var filteredSessions: [SessionDocument] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            session.configuration.course.name.localizedCaseInsensitiveContains(query)
                || session.segments.contains {
                    $0.sourceText.localizedCaseInsensitiveContains(query)
                        || $0.translatedText?.localizedCaseInsensitiveContains(query) == true
                }
        }
    }

    private func sessionTitle(_ session: SessionDocument) -> String {
        session.configuration.course.name.isEmpty
            ? "未命名课堂"
            : session.configuration.course.name
    }

    private func load() async {
        do {
            sessions = try await SessionStore(directoryURL: directoryURL).list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        let documents = offsets.map { filteredSessions[$0] }
        let ids = Set(documents.map(\.id))
        sessions.removeAll { ids.contains($0.id) }
        Task {
            let store = SessionStore(directoryURL: directoryURL)
            for document in documents {
                do {
                    try await store.delete(id: document.id)
                } catch {
                    errorMessage = error.localizedDescription
                    await load()
                    return
                }
            }
        }
    }
}

private enum MobileSessionDetailSurface: String, CaseIterable {
    case summary
    case transcript
}

private struct MobileSessionDetailView: View {
    let document: SessionDocument
    let directoryURL: URL

    @StateObject private var player = MobileAudioPlayer()
    @State private var surface: MobileSessionDetailSurface = .summary

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let audioURL {
                    Button {
                        player.toggle(url: audioURL)
                    } label: {
                        Label(
                            player.isPlaying ? "暂停录音" : "播放录音",
                            systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("内容", selection: $surface) {
                    Text("摘要").tag(MobileSessionDetailSurface.summary)
                    Text("双语全文").tag(MobileSessionDetailSurface.transcript)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding()

            Divider()

            switch surface {
            case .summary:
                summaryView
            case .transcript:
                transcriptView
            }
        }
        .navigationTitle(
            document.configuration.course.name.isEmpty
                ? "未命名课堂"
                : document.configuration.course.name
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享课堂记录")
            }
        }
        .onDisappear { player.stop() }
    }

    private var summaryView: some View {
        let summary = document.summary ?? DeterministicSummaryEngine.makeSummary(for: document)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                summarySection("课程概览", items: summary.overview)
                summarySection("关键概念", items: summary.keyConcepts)
                summarySection("待办事项", items: summary.actionItems)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var transcriptView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.segments) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Text(timestamp(segment.startTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 42, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(segment.sourceText)
                                .font(.body)
                                .textSelection(.enabled)
                            if let translatedText = segment.translatedText {
                                Text(translatedText)
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                    .textSelection(.enabled)
                            } else if segment.translationExclusionReason != nil {
                                Label("中文讨论", systemImage: "text.bubble")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func summarySection(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { entry in
                    Text(entry.element)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var audioURL: URL? {
        guard let fileName = document.audioFileName,
              URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
            return nil
        }
        let url = directoryURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var metadata: String {
        let duration = document.endedAt?.timeIntervalSince(document.startedAt)
            ?? document.segments.map(\.endTime).max()
            ?? 0
        return [
            document.startedAt.formatted(date: .abbreviated, time: .shortened),
            timestamp(duration),
            "\(document.segments.count) 条字幕",
            "Soniox 云端双语",
        ].joined(separator: " · ")
    }

    private var shareText: String {
        let title = document.configuration.course.name.isEmpty
            ? "未命名课堂"
            : document.configuration.course.name
        let transcript = document.segments.map { segment in
            ["[\(timestamp(segment.startTime))] \(segment.sourceText)", segment.translatedText]
                .compactMap { $0 }
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
        return "\(title)\n\(metadata)\n\n\(transcript)"
    }

    private func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
private final class MobileAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        do {
            if player == nil || player?.url != url {
                player = try AVAudioPlayer(contentsOf: url)
                player?.delegate = self
            }
            player?.play()
            isPlaying = true
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor in isPlaying = false }
    }
}
#endif
