@testable import FeatureUI
import XCTest

private final class MockUpdateFeedURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class UpdateCheckerReleaseResolverTests: XCTestCase {
    override func tearDown() {
        MockUpdateFeedURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testBridgeTrackPrefersDateLineReleaseUsingUpdateSequence() {
        let releases = [
            GitHubReleaseRecord(
                tagName: "v0.9.8.57",
                draft: false,
                prerelease: false,
                assets: [],
                body: """
                BETR-Release-Track: bridge
                BETR-Update-Sequence: 2026032302
                """
            ),
            GitHubReleaseRecord(
                tagName: "v0.3.23.2",
                draft: false,
                prerelease: false,
                assets: [],
                body: """
                BETR-Release-Track: date
                BETR-Update-Sequence: 2026032303
                """
            ),
        ]

        let selection = GitHubReleaseResolver.selectLatestStableRelease(
            from: releases,
            currentTrack: .bridge
        )

        XCTAssertEqual(selection?.version, "0.3.23.2")
        XCTAssertEqual(selection?.releaseTrack, .date)
        XCTAssertEqual(selection?.updateSequence, 2026032303)
    }

    func testLegacyTrackStillPrefersBridgeVersionByNumericOrdering() {
        let releases = [
            GitHubReleaseRecord(
                tagName: "v0.9.8.57",
                draft: false,
                prerelease: false,
                assets: [],
                body: """
                BETR-Release-Track: bridge
                BETR-Update-Sequence: 2026032302
                """
            ),
            GitHubReleaseRecord(
                tagName: "v0.3.23.2",
                draft: false,
                prerelease: false,
                assets: [],
                body: """
                BETR-Release-Track: date
                BETR-Update-Sequence: 2026032303
                """
            ),
        ]

        let selection = GitHubReleaseResolver.selectLatestStableRelease(
            from: releases,
            currentTrack: .legacy
        )

        XCTAssertEqual(selection?.version, "0.9.8.57")
        XCTAssertEqual(selection?.releaseTrack, .bridge)
        XCTAssertEqual(selection?.updateSequence, 2026032302)
    }

    func testBridgeTrackFetchesAdditionalReleasePagesForDateLineCutover() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateFeedURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var requestedPages: [Int] = []
        MockUpdateFeedURLProtocol.requestHandler = { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let page = Int(components?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
            requestedPages.append(page)

            let jsonObject: [[String: Any]]
            if page == 1 {
                jsonObject = (1...GitHubReleaseResolver.releasePageSize).map { index in
                    [
                        "tag_name": "v0.9.8.\(index)",
                        "draft": false,
                        "prerelease": false,
                        "assets": [],
                        "body": """
                        BETR-Release-Track: bridge
                        BETR-Update-Sequence: 20260329\(String(format: "%02d", index))
                        """
                    ]
                }
            } else {
                jsonObject = [[
                    "tag_name": "v0.3.30.2",
                    "draft": false,
                    "prerelease": false,
                    "assets": [],
                    "body": """
                    BETR-Release-Track: date
                    BETR-Update-Sequence: 2026033010
                    """
                ]]
            }

            let data = try JSONSerialization.data(withJSONObject: jsonObject)
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, data)
        }

        let releases = try await GitHubReleaseResolver.fetchReleaseRecords(
            currentTrack: .bridge,
            session: session,
            token: nil
        )
        let selection = GitHubReleaseResolver.selectLatestStableRelease(
            from: releases,
            currentTrack: .bridge
        )

        XCTAssertEqual(requestedPages, [1, 2])
        XCTAssertEqual(selection?.version, "0.3.30.2")
        XCTAssertEqual(selection?.releaseTrack, .date)
        XCTAssertEqual(selection?.updateSequence, 2026033010)
    }
}
