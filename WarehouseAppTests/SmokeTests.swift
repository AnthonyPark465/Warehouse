import XCTest
@testable import WarehouseApp

final class SmokeTests: XCTestCase {
    func testAppTargetLinks() {
        let hasConfigurationFile =
            Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil

        XCTAssertEqual(
            FirebaseBootstrap.isConfigured,
            hasConfigurationFile,
            "Firebase configuration should match the presence of GoogleService-Info.plist"
        )
    }
}
