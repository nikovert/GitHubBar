import XCTest
@testable import GitHubBarCore

final class WorktreeCleanupGitHubTests: XCTestCase {
    func testDuplicateStackEntriesDoNotProveCompleteMembership() async throws {
        let client = makeClient(states: ["MERGED", "MERGED"], urls: [12, 12])
        let result = try await client.check(.stack(key), accountLogin: "tester")
        XCTAssertFalse(result.stackComplete)
    }

    func testMergedRootWithOpenMemberIsNotMergedStack() async throws {
        let result = try await makeClient(states: ["MERGED", "OPEN"]).check(.stack(key), accountLogin: "tester")
        XCTAssertTrue(result.merged)
        XCTAssertTrue(result.stackComplete)
        XCTAssertFalse(result.stackMerged)
    }

    func testTruncatedStackAndNullMembersAreIncomplete() async throws {
        for extra in ["truncated", "null", "size"] {
            let result = try await makeClient(extra: extra).check(.stack(key), accountLogin: "tester")
            XCTAssertFalse(result.stackComplete, extra)
        }
    }

    func testCompleteMergedStackIsEligibleMetadata() async throws {
        let result = try await makeClient().check(.stack(key), accountLogin: "tester")
        XCTAssertTrue(result.merged && result.stackComplete && result.stackMerged)
        XCTAssertEqual(result.title, "Finished change")
    }

    func testWrongViewerAndGraphQLErrorsFailClosed() async throws {
        for extra in ["viewer", "error", "missing"] {
            do { _ = try await makeClient(extra: extra).check(.pullRequest(key), accountLogin: "tester"); XCTFail(extra) }
            catch { XCTAssertTrue(error.localizedDescription.contains("GitHub")) }
        }
    }

    private var key: PullRequestKey { try! PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/12")!) }
    private func makeClient(states: [String] = ["MERGED", "MERGED"], urls: [Int] = [12, 13], extra: String = "") -> WorktreeCleanupGitHubClient {
        var nodes: [Any] = zip(states, urls).map { state, number in
            ["pullRequest": ["url": "https://github.com/acme/widget/pull/\(number)", "state": state]]
        }
        if extra == "null" { nodes[1] = NSNull() }
        let pr: [String: Any] = ["title": "Finished change", "state": "MERGED", "headRefOid": String(repeating: "a", count: 40),
            "stack": ["size": extra == "size" ? 3 : 2, "entries": ["nodes": nodes, "pageInfo": ["hasNextPage": extra == "truncated"]]]]
        var json: [String: Any] = ["data": ["viewer": ["login": extra == "viewer" ? "wrong" : "tester"],
            "repository": ["pullRequest": extra == "missing" ? NSNull() as Any : pr as Any]]]
        if extra == "error" { json["errors"] = [["message": "Incomplete"]] }
        return WorktreeCleanupGitHubClient(connection: CleanupConnection(),
            transport: CleanupTransport(data: try! JSONSerialization.data(withJSONObject: json)))
    }
}

private struct CleanupConnection: AccountConnection {
    func inspect(selectedLogin: String?) async -> AccountConnectionResult {
        .connected(ResolvedAccount(login: selectedLogin ?? "", hostname: "github.com", scopes: [],
            accessCoverage: AccessCoverage(isComplete: true), accessToken: GitHubAccessToken("fake")))
    }
}
private struct CleanupTransport: GitHubTransport {
    let data: Data
    func execute(body: Data, accessToken: GitHubAccessToken) async throws -> GitHubTransportResponse {
        .init(statusCode: 200, headers: [:], data: data)
    }
}
