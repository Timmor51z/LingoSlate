#if os(iOS)
import LingoSlateCore
import SwiftUI

public struct MobileCaptionView: View {
    @StateObject private var controller: MobileSessionController
    @StateObject private var profileStore: UserProfileStore
    @ObservedObject private var credentialSettings: MobileCredentialSettings
    @AppStorage("lingoslate.mobile.course.name") private var courseName = ""
    @AppStorage("lingoslate.mobile.course.code") private var courseCode = ""
    @AppStorage("lingoslate.mobile.course.description") private var courseDescription = ""
    @AppStorage("lingoslate.mobile.course.lecturers") private var lecturerNames = ""
    @AppStorage("lingoslate.mobile.course.indian-english") private var usesIndianEnglish = false
    @AppStorage("lingoslate.mobile.course.terms") private var recognitionTermsText = ""
    @State private var showingHistory = false
    @State private var showingSettings = false
    @State private var showingCourseContext = false

    public init(
        controller: MobileSessionController,
        credentialSettings: MobileCredentialSettings
    ) {
        _controller = StateObject(wrappedValue: controller)
        _profileStore = StateObject(wrappedValue: UserProfileStore())
        self.credentialSettings = credentialSettings
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                Divider()
                controls
            }
            .background(Color(.systemBackground))
            .navigationTitle("LingoSlate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingCourseContext = true
                    } label: {
                        Image(systemName: "bolt")
                    }
                    .accessibilityLabel("课程上下文")

                    Button {
                        showingHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("课堂记录")
                }
            }
            .sheet(isPresented: $showingHistory) {
                MobileSessionHistoryView(
                    directoryURL: controller.sessionDirectoryURL
                )
            }
            .sheet(isPresented: $showingSettings) {
                MobileCredentialSettingsView(settings: credentialSettings)
            }
            .sheet(isPresented: $showingCourseContext) {
                MobileCourseContextView(
                    courseName: $courseName,
                    courseCode: $courseCode,
                    courseDescription: $courseDescription,
                    lecturerNames: $lecturerNames,
                    usesIndianEnglish: $usesIndianEnglish,
                    recognitionTermsText: $recognitionTermsText,
                    profileStore: profileStore
                )
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            TextField("课程名称（可选）", text: $courseName)
                .textFieldStyle(.roundedBorder)
                .disabled(!controller.canStart)
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(controller.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Image(systemName: "cloud.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Soniox 云端双语")
                ProgressView(value: Double(controller.inputLevel))
                    .frame(width: 72)
                    .accessibilityLabel("麦克风音量")
            }
        }
        .padding()
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(controller.snapshot.finalSegments) { segment in
                        caption(segment)
                    }
                    if let provisional = controller.snapshot.provisionalSegment {
                        caption(provisional)
                            .opacity(0.65)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding()
            }
            .onChange(of: controller.snapshot) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("latest", anchor: .bottom)
                }
            }
        }
    }

    private func caption(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(segment.sourceText)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            if let translated = segment.translatedText {
                Text(translated)
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(segment.id)
    }

    private var controls: some View {
        ZStack {
            HStack {
                Button {
                    controller.addMarker()
                } label: {
                    Image(systemName: controller.markers.isEmpty ? "bookmark" : "bookmark.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(controller.state != .listening)
                .accessibilityLabel("添加书签")
                Spacer()
            }

            Button {
                Task {
                    if controller.canStart {
                        await controller.start(
                            course: preparedCourse,
                            profile: profileStore.profile
                        )
                    } else {
                        await controller.stop()
                    }
                }
            } label: {
                Image(systemName: controller.canStart ? "mic.fill" : "stop.fill")
                    .font(.title2)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(controller.canStart ? .green : .red)
            .disabled(controller.state == .finishing)
            .accessibilityLabel(controller.canStart ? "开始课堂" : "结束课堂")
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var preparedCourse: Course {
        let terms = MobileCourseContextBuilder.terms(
            courseName: courseName,
            schoolName: profileStore.schoolName,
            manualText: recognitionTermsText
        )
        return Course(
            name: CourseNameNormalizer.normalize(courseName),
            code: MobileCourseContextBuilder.optional(courseCode),
            roughDescription: MobileCourseContextBuilder.optional(courseDescription),
            lecturerNames: MobileCourseContextBuilder.values(lecturerNames),
            lecturerAccent: usesIndianEnglish ? .indianEnglish : nil,
            recognitionTerms: terms,
            contextMaturity: terms.isEmpty ? 0 : 1
        )
    }

    private var statusColor: Color {
        switch controller.state {
        case .listening:
            return .green
        case .failed:
            return .red
        case .preparing, .finishing:
            return .orange
        case .idle, .complete:
            return .secondary
        }
    }
}

private struct MobileCourseContextView: View {
    @Binding var courseName: String
    @Binding var courseCode: String
    @Binding var courseDescription: String
    @Binding var lecturerNames: String
    @Binding var usesIndianEnglish: Bool
    @Binding var recognitionTermsText: String
    @ObservedObject var profileStore: UserProfileStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("课程") {
                    TextField("课程名称（可选）", text: $courseName)
                    TextField("课程代码", text: $courseCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("课程内容简介", text: $courseDescription, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("讲师姓名", text: $lecturerNames)
                    Toggle("Indian English", isOn: $usesIndianEnglish)
                }

                Section("学校与地区") {
                    TextField("学校", text: $profileStore.schoolName)
                    TextField("国家或地区代码", text: $profileStore.regionCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("识别术语") {
                    TextEditor(text: $recognitionTermsText)
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                    Button {
                        recognitionTermsText = MobileCourseContextBuilder.terms(
                            courseName: courseName,
                            schoolName: profileStore.schoolName,
                            manualText: recognitionTermsText
                        ).joined(separator: "\n")
                    } label: {
                        Label("自动准备术语", systemImage: "bolt.fill")
                    }
                }
            }
            .navigationTitle("课程上下文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private enum MobileCourseContextBuilder {
    static func terms(
        courseName: String,
        schoolName: String,
        manualText: String
    ) -> [String] {
        merge(
            CourseTermSeedBuilder.suggestions(
                courseName: courseName,
                schoolName: schoolName
            ) + values(manualText)
        )
    }

    static func values(_ text: String) -> [String] {
        text.split { character in
            character.isNewline
                || character == ","
                || character == ";"
                || character == "，"
                || character == "；"
        }.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    static func optional(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func merge(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter {
            seen.insert($0.lowercased()).inserted
        }
    }
}

private struct MobileCredentialSettingsView: View {
    @ObservedObject var settings: MobileCredentialSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Soniox Broker") {
                    TextField("HTTPS 服务地址", text: $settings.endpointText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Broker token", text: $settings.brokerToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let errorMessage = settings.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if settings.save() { dismiss() }
                    }
                }
            }
        }
    }
}
#endif
