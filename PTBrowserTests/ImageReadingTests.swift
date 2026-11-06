import XCTest
import UIKit
@testable import PTBrowser

final class ImageReadingTests: XCTestCase {
    func testLoadingTallImageAboveViewportPreservesReadingPosition() throws {
        var layout = ImageReadingLayout()
        layout.rebuild(width: 400, aspects: [1, 1, 1])
        let anchor = try XCTUnwrap(layout.anchor(at: 550))
        layout.rebuild(width: 400, aspects: [4, 1, 1])
        let offset = layout.offset(for: anchor)
        XCTAssertEqual(offset, 1750)
        XCTAssertEqual(offset - layout.frames[1].minY, 150, "Loading an earlier image must not move the current image under the finger")
        XCTAssertEqual(layout.frames[0].maxY, layout.frames[1].minY, "Image boundaries must be seamless")
        let bouncing = try XCTUnwrap(layout.anchor(at: -45))
        layout.rebuild(width: 400, aspects: [2, 1, 1])
        XCTAssertEqual(layout.offset(for: bouncing), -45, "A height update must preserve the user's pull-down distance")
    }
    func testRotationAndReverseScrollingKeepAccuratePositions() throws {
        var layout = ImageReadingLayout()
        layout.rebuild(width: 400, aspects: [3, 1, 2])
        let anchor = try XCTUnwrap(layout.anchor(at: 1300))
        layout.rebuild(width: 600, aspects: [3, 1, 2])
        XCTAssertEqual(layout.offset(for: anchor, scale: 1.5), 1950)
        XCTAssertEqual(layout.indices(in: CGRect(x: 0, y: 1790, width: 600, height: 400)), 0..<2)
        XCTAssertEqual(layout.indices(in: CGRect(x: 0, y: 1800, width: 600, height: 400)), 1..<2)
        XCTAssertEqual(layout.indices(in: CGRect(x: 0, y: 0, width: 600, height: 400)), 0..<1)
    }
    func testReadingDecodeUsesDisplayResolutionAndHonorsOrientation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let size = CGSize(width: 1200, height: 4800)
        let url = root.appendingPathComponent("long.png")
        let data = UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
        try data.write(to: url)
        let image = try XCTUnwrap(ImageDecoder.decode(url, targetPixelWidth: 300))
        XCTAssertEqual(image.size.width, 300)
        XCTAssertEqual(image.size.height, 1200)
        // Rotated camera images still use their displayed width for downsampling.
        let rotated = UIImage(cgImage: try XCTUnwrap(image.cgImage), scale: 1, orientation: .right)
        let rotatedURL = root.appendingPathComponent("rotated.jpg")
        try XCTUnwrap(rotated.jpegData(compressionQuality: 0.8)).write(to: rotatedURL)
        let decoded = try XCTUnwrap(ImageDecoder.decode(rotatedURL, targetPixelWidth: 240))
        XCTAssertEqual(decoded.size.width, 240)
        XCTAssertEqual(decoded.size.height, 60)
    }
}
