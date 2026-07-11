import SwiftUI

@main
struct ClassBridgeMacApp: App {
    var body: some Scene {
        WindowGroup {
            ClassroomWorkspaceView()
        }
        .defaultSize(width: 1_080, height: 720)
        .windowResizability(.contentMinSize)
    }
}
