import XCTest
import Network
import UIKit
import AVFoundation
@testable import PTBrowser

/// A real loopback HTTP server exercises URLSession response validation, hashing and Files import.
private final class HTTPFixture: @unchecked Sendable {
    let listener: NWListener
    let body: Data
    let mime: String
    let status: Int
    let disposition: String
    var port: UInt16 { listener.port!.rawValue }
    init(body: Data, mime: String, status: Int = 200, filename: String? = nil) throws {
        self.body = body; self.mime = mime; self.status = status
        self.disposition = filename.map { "Content-Disposition: attachment; filename=\"\($0)\"\r\n" } ?? ""
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [body, mime, status, disposition] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                    var response = Data("HTTP/1.1 \(status) Response\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\n\(disposition)Connection: close\r\n\r\n".utf8)
                    response.append(body)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: .global())
        }
    }
    deinit { listener.cancel() }
}

@MainActor final class DownloadTests: XCTestCase {
    private var previousBookmark: Data?
    override func setUp() { previousBookmark = UserDefaults.standard.data(forKey: "libraryBookmark") }
    override func tearDown() {
        if let previousBookmark { UserDefaults.standard.set(previousBookmark, forKey: "libraryBookmark") }
        else { UserDefaults.standard.removeObject(forKey: "libraryBookmark") }
    }
    private func waitForFinish(_ downloads: DownloadCenter) async throws -> DownloadJob {
        for _ in 0..<150 {
            if let job = downloads.jobs.first, [.completed, .failed].contains(job.state) { return job }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PTError.message("Download did not finish")
    }
    private func library() async throws -> LibraryStore {
        let store = LibraryStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await store.selectFolder(root); store.notice = nil
        return store
    }
    func testImageDownloadValidatesAndImportsWithSHA256() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let data = renderer.pngData { context in UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16)) }
        let server = try HTTPFixture(body: data, mime: "image/png")
        try await server.start()
        let store = try await library()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let center = DownloadCenter(configuration: .ephemeral, storageDirectory: store.root.appendingPathComponent(".queue"))
        center.library = store
        await center.enqueue(MediaCandidate(url: URL(string: "http://127.0.0.1:\(server.port)/photo.png")!, kind: .image, source: "test"), tab: nil)
        let job = try await waitForFinish(center)
        XCTAssertEqual(job.state, .completed, job.message ?? "")
        XCTAssertEqual(job.sha256?.count, 64)
        let snapshot = try await store.repository.snapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        let actual = try Data(contentsOf: store.root.appendingPathComponent(snapshot.items[0].name))
        XCTAssertEqual(actual, data)
        center.remove(job.id)
    }
    func testHTMLMasqueradingAsMediaIsRejected() async throws {
        let server = try HTTPFixture(body: Data("<html>Sign in</html>".utf8), mime: "text/html")
        try await server.start()
        let store = try await library()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let center = DownloadCenter(configuration: .ephemeral, storageDirectory: store.root.appendingPathComponent(".queue")); center.library = store
        await center.enqueue(MediaCandidate(url: URL(string: "http://127.0.0.1:\(server.port)/movie.mp4")!, kind: .video, source: "test"), tab: nil)
        let job = try await waitForFinish(center)
        XCTAssertEqual(job.state, .failed)
        let snapshot = try await store.repository.snapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
        center.remove(job.id)
    }
    func testInvalidImageAndMismatchedExpectedHashAreRejected() async throws {
        let server = try HTTPFixture(body: Data("not-a-real-image".utf8), mime: "image/png")
        try await server.start()
        let store = try await library()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let center = DownloadCenter(configuration: .ephemeral, storageDirectory: store.root.appendingPathComponent(".queue")); center.library = store
        await center.enqueue(MediaCandidate(url: URL(string: "http://127.0.0.1:\(server.port)/fake.png")!, kind: .image, source: "test"), tab: nil)
        let invalid = try await waitForFinish(center)
        XCTAssertEqual(invalid.state, .failed)
        center.remove(invalid.id)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        let validServer = try HTTPFixture(body: data, mime: "image/png")
        try await validServer.start()
        await center.enqueue(MediaCandidate(url: URL(string: "http://127.0.0.1:\(validServer.port)/valid.png")!, kind: .image, source: "test"), tab: nil, expectedSHA256: String(repeating: "0", count: 64))
        let mismatch = try await waitForFinish(center)
        XCTAssertEqual(mismatch.state, .failed)
        let snapshot = try await store.repository.snapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
        center.remove(mismatch.id)
    }
    func testDownloadedMP4CanOpenAndEncryptFromAliasedFilesFolder() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Playback-Test", withExtension: "mp4"))
        let data = try Data(contentsOf: source)
        let server = try HTTPFixture(body: data, mime: "video/mp4")
        try await server.start()
        let store = try await library()
        let actualRoot = store.root
        let alias = actualRoot.deletingLastPathComponent().appendingPathComponent("DownloadAlias-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actualRoot)
        defer { try? FileManager.default.removeItem(at: alias); try? FileManager.default.removeItem(at: actualRoot) }
        await store.selectFolder(alias)
        let center = DownloadCenter(configuration: .ephemeral, storageDirectory: actualRoot.appendingPathComponent(".queue"))
        center.library = store
        await center.enqueue(MediaCandidate(url: URL(string: "http://127.0.0.1:\(server.port)/downloaded.mp4")!, kind: .video, source: "test"), tab: nil)
        let job = try await waitForFinish(center)
        XCTAssertEqual(job.state, .completed, job.message ?? "")
        let snapshot = try await store.repository.snapshot()
        let item = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(item.relativePath, "downloaded.mp4")
        let publicURL = try await store.repository.playableURL(item)
        let playable = try await AVURLAsset(url: publicURL).load(.isPlayable)
        XCTAssertTrue(playable)
        try await store.repository.createVault(password: "download-test-password")
        try await store.repository.encrypt(item)
        await store.repository.lock()
        try await store.repository.unlock(password: "download-test-password")
        let encrypted = try await store.repository.snapshot()
        let hidden = try XCTUnwrap(encrypted.items.first)
        let clear = try await store.repository.playableURL(hidden)
        XCTAssertEqual(try Data(contentsOf: clear), data)
        center.remove(job.id)
    }

    func testDownloadedVideoKeepsWebTitleDespiteServerFilenameAndNumbersCollisions() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Playback-Test", withExtension: "mp4"))
        let data = try Data(contentsOf: source)
        let server = try HTTPFixture(body: data, mime: "video/mp4", filename: "hash-839192.mp4")
        try await server.start()
        let store = try await library()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let center = DownloadCenter(configuration: .ephemeral, storageDirectory: store.root.appendingPathComponent(".queue"))
        center.library = store
        let candidate = MediaCandidate(url: URL(string: "http://127.0.0.1:\(server.port)/asset.mp4")!, kind: .video, source: "test", mediaTitle: "海边旅行 第一集", pageTitle: "旅行 视频站", titlePriority: 40)
        await center.enqueue(candidate, tab: nil)
        let first = try await waitForFinish(center)
        XCTAssertEqual(first.state, .completed, first.message ?? "")
        XCTAssertEqual(first.name, "海边旅行 第一集.mp4")
        await center.enqueue(candidate, tab: nil)
        let second = try await waitForFinish(center)
        XCTAssertEqual(second.state, .completed, second.message ?? "")
        XCTAssertEqual(second.name, "海边旅行 第一集 (1).mp4")
        let snapshot = try await store.repository.snapshot()
        XCTAssertEqual(Set(snapshot.items.map(\.name)), [first.name, second.name])
        let item = try XCTUnwrap(snapshot.items.first { $0.name == first.name })
        let original = try await store.repository.playableURL(item)
        let playable = try await AVURLAsset(url: original).load(.isPlayable)
        XCTAssertTrue(playable)
        try await store.repository.createVault(password: "web-name-password")
        try await store.repository.encrypt(item)
        let encrypted = try await store.repository.snapshot()
        let hidden = try XCTUnwrap(encrypted.items.first(where: \.isEncrypted))
        XCTAssertEqual(hidden.name, first.name)
        let decrypted = try await store.repository.playableURL(hidden)
        XCTAssertEqual(try Data(contentsOf: decrypted), data)
        // Queues from earlier versions have no preferredTitle field and must remain readable.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        legacy.removeValue(forKey: "preferredTitle")
        let decoded = try JSONDecoder().decode(DownloadJob.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.preferredTitle)
        center.remove(first.id); center.remove(second.id)
    }

    func testDownloadedImageUsesPageTitleAndActualMIMEExtension() async throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let server = try HTTPFixture(body: data, mime: "image/png", filename: "random-hash.jpg")
        try await server.start()
        let store = try await library()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let center = DownloadCenter(configuration: .ephemeral, storageDirectory: store.root.appendingPathComponent(".queue"))
        center.library = store
        await center.enqueue(MediaCandidate(url: URL(string: "http://127.0.0.1:\(server.port)/opaque")!, kind: .image, source: "test", pageTitle: "旅行相册 v1.2"), tab: nil)
        let job = try await waitForFinish(center)
        XCTAssertEqual(job.state, .completed, job.message ?? "")
        XCTAssertEqual(job.name, "旅行相册 v1.2.png")
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(job.name)), data)
        center.remove(job.id)
    }

}
