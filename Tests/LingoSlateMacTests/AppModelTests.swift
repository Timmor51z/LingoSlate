import LingoSlateCore
import XCTest
@testable import LingoSlateMac

final class AppModelTests: XCTestCase {
    @MainActor
    func testCourseNameIsOptionalForStartAndWarmup() throws {
        let suiteName = "LingoSlateAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileStore = UserProfileStore(
            defaults: defaults,
            legacyBundleIdentifiers: []
        )
        let model = AppModel(profileStore: profileStore)

        model.courseName = "   "

        XCTAssertTrue(model.canStart)
        XCTAssertTrue(model.canWarmUp)
    }
}
