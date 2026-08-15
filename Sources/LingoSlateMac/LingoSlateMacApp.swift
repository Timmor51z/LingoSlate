import LingoSlateCore
import SwiftUI

@main
struct LingoSlateMacApp: App {
    @StateObject private var profileStore = UserProfileStore()
    @StateObject private var sonioxCredentialStore = SonioxCredentialStore()

    var body: some Scene {
        WindowGroup {
            ClassroomWorkspaceView(
                profileStore: profileStore,
                sonioxCredentialStore: sonioxCredentialStore
            )
        }
        .defaultSize(width: 1_000, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            UserProfileSettingsView(
                profileStore: profileStore,
                sonioxCredentialStore: sonioxCredentialStore
            )
        }
    }
}
