import LingoSlateCore
import SwiftUI

@main
struct LingoSlateMacApp: App {
    @StateObject private var profileStore = UserProfileStore()

    var body: some Scene {
        WindowGroup {
            ClassroomWorkspaceView(profileStore: profileStore)
        }
        .defaultSize(width: 1_080, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            UserProfileSettingsView(profileStore: profileStore)
        }
    }
}
