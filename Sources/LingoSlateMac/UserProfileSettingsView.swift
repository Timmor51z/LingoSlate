import LingoSlateCore
import SwiftUI

struct UserProfileSettingsView: View {
    @ObservedObject var profileStore: UserProfileStore
    @ObservedObject var sonioxCredentialStore: SonioxCredentialStore
    @State private var sonioxAPIKey = ""

    private let regions = RegionOption.all

    var body: some View {
        Form {
            Section("学习资料") {
                TextField("学校", text: $profileStore.schoolName)

                Picker("国家或地区", selection: $profileStore.regionCode) {
                    ForEach(regions) { region in
                        Text(region.name).tag(region.code)
                    }
                }
            }

            Section("Soniox") {
                SecureField("API Key", text: $sonioxAPIKey)

                HStack {
                    Button("保存") {
                        sonioxCredentialStore.save(sonioxAPIKey)
                        sonioxAPIKey = ""
                    }
                    .disabled(sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("移除", role: .destructive) {
                        sonioxCredentialStore.clear()
                        sonioxAPIKey = ""
                    }
                    .disabled(!sonioxCredentialStore.hasAPIKey)

                    Spacer()

                    if sonioxCredentialStore.hasAPIKey {
                        Label(
                            sonioxCredentialStore.usesEnvironment ? "环境变量" : "已保存",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }

                if let errorMessage = sonioxCredentialStore.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Label("资料仅保存在本机", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 320, idealHeight: 360)
    }
}

private struct RegionOption: Identifiable {
    var code: String
    var name: String

    var id: String { code }

    static var all: [RegionOption] {
        Locale.Region.isoRegions.compactMap { region in
            let code = region.identifier
            guard let name = Locale.current.localizedString(forRegionCode: code) else {
                return nil
            }
            return RegionOption(code: code, name: name)
        }.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
