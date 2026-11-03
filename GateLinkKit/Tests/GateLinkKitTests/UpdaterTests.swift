import CryptoKit
import Foundation
import Testing
@testable import GateLinkKit

@Suite(.serialized) struct UpdaterTests {
    func release(tag: String, digest: String? = "sha256:ABCD") -> Data {
        let digestJSON = digest.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"tag_name": "\(tag)", "html_url": "https://github.com/henrydavl/gatelink/releases/tag/\(tag)", "body": "Notes",
         "assets": [
          {"name": "GateLink-x64.pkg", "size": 1, "digest": "sha256:ffff", "browser_download_url": "https://example.com/x64.pkg"},
          {"name": "GateLink-arm64.pkg", "size": 4, "digest": \(digestJSON), "browser_download_url": "https://example.com/arm64.pkg"}
         ]}
        """.utf8)
    }

    @Test func picksThePackageForThisCPU() throws {
        let update = try #require(try Updater.update(fromRelease: release(tag: "v2.1.0"), currentVersion: "2.0.3", architecture: "arm64"))
        #expect(update == AppUpdate(
            version: "2.1.0",
            notes: "Notes",
            pageURL: URL(string: "https://github.com/henrydavl/gatelink/releases/tag/v2.1.0")!,
            packageURL: URL(string: "https://example.com/arm64.pkg")!,
            sha256: "abcd",
            size: 4
        ))
    }

    @Test func ignoresReleasesThatAreNotNewer() throws {
        #expect(try Updater.update(fromRelease: release(tag: "v2.0.3"), currentVersion: "2.0.3", architecture: "arm64") == nil)
        #expect(try Updater.update(fromRelease: release(tag: "v2.0.2"), currentVersion: "2.0.3", architecture: "arm64") == nil)
    }

    @Test func refusesAPackageWithoutAChecksum() {
        #expect(throws: GateLinkError.self) {
            try Updater.update(fromRelease: release(tag: "v2.1.0", digest: nil), currentVersion: "2.0.3", architecture: "arm64")
        }
    }

    @Test func comparesVersionsNumerically() {
        #expect(Updater.isNewer("2.0.10", than: "2.0.9"))
        #expect(Updater.isNewer("2.1", than: "2.0.9"))
        #expect(!Updater.isNewer("2.0", than: "2.0.0"))
        #expect(!Updater.isNewer("1.9.9", than: "2.0.0"))
        #expect(Updater.isNewer("2.0.3", than: "0.0.0"))
    }

    @Test func downloadAcceptsOnlyTheReleasedBytes() async throws {
        let body = Data("pkg!".utf8)
        StubProtocol.body = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let updater = Updater(currentVersion: "2.0.3", session: URLSession(configuration: configuration))
        let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        var update = AppUpdate(
            version: "2.1.0", notes: "", pageURL: URL(string: "https://example.com")!,
            packageURL: URL(string: "https://example.com/arm64.pkg")!, sha256: sha, size: body.count
        )

        let file = try await updater.download(update) { _ in }
        #expect(try Data(contentsOf: file) == body)
        try FileManager.default.removeItem(at: file)

        update.sha256 = String(repeating: "0", count: 64)
        await #expect(throws: GateLinkError.self) { try await updater.download(update) { _ in } }
    }
}

/// Serves `body` for every request.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
