import XCTest
import WebKit
@testable import PTBrowser

@MainActor final class BrowserTests: XCTestCase {
    func testAddressAndSearchResolution() {
        XCTAssertEqual(BrowserTab.navigationURL("example.com/path")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(BrowserTab.navigationURL("http://example.com")?.scheme, "http")
        XCTAssertEqual(URLComponents(url: BrowserTab.navigationURL("长图 收藏")!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "长图 收藏")
        XCTAssertNil(BrowserTab.navigationURL("   "))
    }
    func testMediaSnifferFindsDOMLazySrcsetAndDynamicVideo() async throws {
        let tab = BrowserTab(isPrivate: true)
        tab.webView.loadHTMLString("""
        <html><body><img src="https://example.invalid/photo.jpg" width="600"><img data-src="https://example.invalid/lazy.webp"><img srcset="https://example.invalid/one.png 1x, https://example.invalid/two.png 2x"><video src="https://example.invalid/movie.mp4" poster="https://example.invalid/poster.jpg"></video><a href="https://example.invalid/master.m3u8">HLS</a></body></html>
        """, baseURL: URL(string: "https://example.invalid"))
        for _ in 0..<80 {
            if tab.candidates.count >= 7 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let paths = Set(tab.candidates.map { $0.url.lastPathComponent })
        XCTAssertTrue(paths.isSuperset(of: ["photo.jpg", "lazy.webp", "one.png", "two.png", "movie.mp4", "poster.jpg", "master.m3u8"]), "Found: \(paths)")
        _ = try await tab.webView.evaluateJavaScript("const v=document.createElement('video');v.src='https://example.invalid/dynamic.mp4';document.body.appendChild(v);true")
        for _ in 0..<30 { if tab.candidates.contains(where: { $0.name == "dynamic.mp4" }) { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(tab.candidates.contains { $0.name == "dynamic.mp4" })
        XCTAssertFalse(tab.webView.configuration.websiteDataStore.isPersistent)
        tab.webView.stopLoading()
    }
    func testBridgeRejectsNonNetworkURLsAndDeduplicates() {
        let tab = BrowserTab(isPrivate: true)
        tab.receive([["url": "file:///etc/passwd", "kind": "image"], ["url": "blob:https://example.com/123", "kind": "video"], ["url": "https://example.com/image", "kind": "image", "width": 600]])
        tab.receive([["url": "https://example.com/image", "kind": "image", "width": 1000]])
        XCTAssertEqual(tab.candidates.count, 1); XCTAssertEqual(tab.candidates.first?.width, 1000)
    }
    func testWebNamesComeFromMediaDescriptionsCaptionsAndPageTitle() async throws {
        let tab = BrowserTab(isPrivate: true)
        tab.webView.loadHTMLString("""
        <html><head><title>网页标签标题</title><meta property="og:title" content="旅行日记 v1.2"></head><body>
        <img id="named" alt="海边的日落" src="https://example.invalid/hash-a.jpg">
        <figure><img src="https://example.invalid/hash-b.jpg"><figcaption>山间清晨</figcaption></figure>
        <video title="旅途第一集"><source src="https://example.invalid/hash-c.mp4"></video>
        <img src="https://example.invalid/hash-d.jpg" alt="image">
        <a href="https://example.invalid/hash-e.mp4">旅途第二集</a>
        </body></html>
        """, baseURL: URL(string: "https://example.invalid"))
        for _ in 0..<80 { if tab.candidates.count >= 5 { break }; try await Task.sleep(for: .milliseconds(100)) }
        func name(_ file: String) -> String? { tab.candidates.first { $0.url.lastPathComponent == file }?.name }
        XCTAssertEqual(name("hash-a.jpg"), "海边的日落")
        XCTAssertEqual(name("hash-b.jpg"), "山间清晨")
        XCTAssertEqual(name("hash-c.mp4"), "旅途第一集")
        XCTAssertEqual(name("hash-d.jpg"), "旅行日记 v1.2")
        XCTAssertEqual(name("hash-e.mp4"), "旅途第二集")
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('#named').alt='日落的新名字';true")
        for _ in 0..<40 { if name("hash-a.jpg") == "日落的新名字" { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(name("hash-a.jpg"), "日落的新名字")
        // A later network report must not replace an element's descriptive title.
        tab.receive([["url": "https://example.invalid/hash-a.jpg", "kind": "image", "pageTitle": "旅行日记 v1.2", "width": 1200]])
        XCTAssertEqual(name("hash-a.jpg"), "日落的新名字")
        XCTAssertEqual(tab.candidates.first { $0.url.lastPathComponent == "hash-a.jpg" }?.width, 1200)
        tab.webView.stopLoading()
    }
    func testSourceOfflineVideosLeadAndEncryptedStreamsStayVisible() {
        let tab = BrowserTab(isPrivate: true)
        tab.receive([
            ["url": "https://example.com/poster.jpg", "kind": "image"],
            ["url": "https://example.com/master.m3u8", "kind": "video"],
            ["url": "https://example.com/clip.mp4", "kind": "video"],
            ["url": "https://example.com/segment.ts", "kind": "video"],
            ["url": "https://example.com/protected.mp4", "kind": "video", "encrypted": true, "protection": "网页已绑定 DRM 密钥，过期后可能无法再查看，请尽快下载。"]
        ])
        XCTAssertEqual(tab.candidates.map(\.url.lastPathComponent), ["clip.mp4", "master.m3u8", "segment.ts", "protected.mp4", "poster.jpg"])
        XCTAssertTrue(tab.candidates[0].isSourceOfflineVideo)
        XCTAssertEqual(tab.candidates[3].protectionWarning, "网页已绑定 DRM 密钥，过期后可能无法再查看，请尽快下载。")
        XCTAssertEqual(tab.candidates[3].deliveryLabel, "加密视频")
        tab.receive([["url": "https://example.com/master.m3u8", "kind": "video", "encrypted": true, "protection": "HLS 使用 AES-128 加密，密钥过期后可能无法再查看，请尽快下载。"]])
        XCTAssertEqual(tab.candidates.map(\.url.lastPathComponent), ["clip.mp4", "segment.ts", "master.m3u8", "protected.mp4", "poster.jpg"])
        XCTAssertTrue(tab.candidates[2].streamEncrypted)
    }

}
