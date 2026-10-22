import XCTest
@testable import GitHubBarCore

final class LocalWorkspaceStoreErrorTests: XCTestCase {
    func testWorkspaceStoreFailuresExplainRecoveryWithoutDiscardingData() {
        XCTAssertTrue(
            LocalWorkspaceStoreError.corrupt.localizedDescription.contains("Back up workspace.json")
        )
        XCTAssertTrue(
            LocalWorkspaceStoreError.incompatibleVersion.localizedDescription.contains("Update GitHubBar")
        )
        XCTAssertTrue(
            LocalWorkspaceStoreError.lockUnavailable.localizedDescription.contains("permissions")
        )
    }
}
