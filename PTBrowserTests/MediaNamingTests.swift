import XCTest
@testable import PTBrowser

final class MediaNamingTests: XCTestCase {
    func testPreservesTitleDotsAndUsesMediaTypeForExtension() {
        let url = URL(string: "https://cdn.example.com/hash.webm")!
        XCTAssertEqual(MediaNaming.filename(title: "我的旅行 v1.2", kind: .video, url: url, mime: "video/mp4", suggestedFilename: "random.mp4"), "我的旅行 v1.2.mp4")
        XCTAssertEqual(MediaNaming.filename(title: "我的视频.mp4", kind: .video, url: url, mime: "video/mp4"), "我的视频.mp4")
        XCTAssertEqual(MediaNaming.filename(title: "旅行 v1.2", kind: .video, url: URL(string: "https://example.com/master.m3u8")!, isHLS: true), "旅行 v1.2.movpkg")
    }
    func testSafeUnicodeTitleAndResourceFallback() {
        let url = URL(string: "https://cdn.example.com/hash.mp4")!
        let title = "../旅行/照片: \n" + String(repeating: "中文🌅", count: 150)
        let filename = MediaNaming.filename(title: title, kind: .video, url: url)
        XCTAssertLessThanOrEqual(filename.utf8.count, 230)
        XCTAssertFalse(filename.hasPrefix("."))
        XCTAssertFalse(filename.contains("/")); XCTAssertFalse(filename.contains("\n"))
        XCTAssertEqual((filename as NSString).pathExtension, "mp4")
        XCTAssertEqual(MediaNaming.filename(title: " \n ", kind: .video, url: url, mime: "application/octet-stream", suggestedFilename: "original.mp4"), "original.mp4")
    }
}
