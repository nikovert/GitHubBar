import Foundation
import GitHubBarCore
import XCTest
@testable import GitHubBar

@MainActor
final class ReviewAgentModelTests: XCTestCase {
    func testSaveDoesNotLaunchAndReloadRestoresLiteralConfiguration() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentReviewStore(directoryURL: directory)
        let model = ReviewAgentModel(store: store)
        await model.load()
        model.draft.displayName = "Team reviewer"
        model.draft.mode = .managed
        model.draft.executable = "/usr/bin/true"
        model.draft.workingDirectory = "/private/tmp"
        model.argumentsText = #"["a b", ";", "$(literal)"]"#
        model.priorityAuthorsText = "colleague"
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.processState, .stopped)
        let reloaded = ReviewAgentModel(store: store)
        await reloaded.load()
        XCTAssertEqual(reloaded.draft.displayName, "Team reviewer")
        XCTAssertEqual(reloaded.draft.arguments, ["a b", ";", "$(literal)"])
        XCTAssertEqual(reloaded.priorityAuthorsText, "colleague")
        XCTAssertEqual(reloaded.processState, .stopped)
    }

    func testMismatchedAccountCannotStartWorker() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentReviewStore(directoryURL: directory)
        _ = try await store.update { document in
            document.accountLogin = "original"
            document.enabled = true
            document.reviewAgentConnection = ReviewAgentConnection(mode: .managed,
                executable: "/usr/bin/sleep", arguments: ["30"], workingDirectory: "/private/tmp")
        }
        let model = ReviewAgentModel(store: store)
        await model.load()
        await model.updateMonitoredAccount("different")
        await model.start()
        XCTAssertEqual(model.processState, .stopped)
        XCTAssertNotNil(model.errorMessage)
    }

    func testConfigurationTestDoesNotLaunchAndAccountChangeStopsManagedWorker() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("Contents/MacOS/GitHubBarWorkspaceCLI")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let store = AgentReviewStore(directoryURL: directory)
        _ = try await store.update { document in
            document.accountLogin = "original"
            document.enabled = true
            document.reviewAgentConnection = ReviewAgentConnection(mode: .managed,
                executable: "/bin/sleep", arguments: ["30"], workingDirectory: "/private/tmp")
        }
        let model = ReviewAgentModel(store: store, bundleURL: directory)
        await model.load()
        await model.updateMonitoredAccount("original")
        await model.test()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.processState, .stopped)
        await model.start()
        XCTAssertEqual(model.processState, .running)
        await model.updateMonitoredAccount("different")
        XCTAssertEqual(model.processState, .stopped)
        await model.start()
        XCTAssertEqual(model.processState, .stopped)
        XCTAssertNotNil(model.errorMessage)
    }
}
