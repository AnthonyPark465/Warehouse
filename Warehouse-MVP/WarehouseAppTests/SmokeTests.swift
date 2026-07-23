import XCTest
@testable import WarehouseApp

final class SmokeTests: XCTestCase {
    func testAppTargetLinks() {
        XCTAssertFalse(FirebaseBootstrap.isConfigured, "Firebase should stay unconfigured without GoogleService-Info.plist")
    }
}
