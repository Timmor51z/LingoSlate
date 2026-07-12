import LingoSlateCore
import SwiftUI

struct UserProfileSettingsView: View {
    @ObservedObject var profileStore: UserProfileStore

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

            Section {
                Label("资料仅保存在本机", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 230)
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
