import LingoSlateMobile
import SwiftUI

@main
struct LingoSlateIOSApp: App {
    @StateObject private var controller: MobileSessionController
    @StateObject private var credentialSettings: MobileCredentialSettings

    init() {
        let settings = MobileCredentialSettings()
        _credentialSettings = StateObject(wrappedValue: settings)
        _controller = StateObject(
            wrappedValue: MobileSessionController(
                apiKeyProvider: { try await settings.temporaryAPIKey() }
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            MobileCaptionView(
                controller: controller,
                credentialSettings: credentialSettings
            )
        }
    }
}
