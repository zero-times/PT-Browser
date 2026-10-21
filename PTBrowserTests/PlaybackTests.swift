import XCTest
import AVKit
@testable import PTBrowser

@MainActor final class PlaybackTests: XCTestCase {
    private func media() throws -> (URL, MediaItem) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Playback-Test", withExtension: "mp4"))
        let item = MediaItem(id: UUID().uuidString, name: url.lastPathComponent, relativePath: url.lastPathComponent, kind: .video, bytes: 0, created: Date())
        return (url, item)
    }
    func testRepeatedPresentationPreservesThePlayingItemAndSession() throws {
        let (url, item) = try media()
        let model = PlaybackModel()
        model.open(url, item: item, rate: 1, muted: false) {}
        defer { model.stop() }
        let player = try XCTUnwrap(model.player)
        let playingItem = try XCTUnwrap(player.currentItem)
        let session = model.sessionID
        model.isFullScreen = true
        model.open(url, item: item, rate: 1.5, muted: true) {}
        XCTAssertTrue(model.player === player)
        XCTAssertTrue(model.player?.currentItem === playingItem)
        XCTAssertEqual(model.sessionID, session)
        XCTAssertEqual(model.mediaID, item.id)
        XCTAssertTrue(model.isFullScreen)
        XCTAssertEqual(model.player?.isMuted, true)
    }
    func testInlineTeardownDoesNotDetachAFullScreenPlayer() throws {
        let (url, item) = try media()
        let model = PlaybackModel()
        model.open(url, item: item, rate: 1, muted: false) {}
        defer { model.stop() }
        let controller = AVPlayerViewController()
        controller.player = model.player
        let coordinator = NativePlayer.Coordinator(playback: model)
        model.isFullScreen = true
        NativePlayer.dismantleUIViewController(controller, coordinator: coordinator)
        XCTAssertTrue(controller.player === model.player)
        XCTAssertNotNil(controller.player?.currentItem)
        model.isFullScreen = false
        NativePlayer.dismantleUIViewController(controller, coordinator: coordinator)
        XCTAssertNil(controller.player)
        XCTAssertNotNil(model.player?.currentItem)
    }
    func testActualCloseStopsAndReleasesThePlayer() throws {
        let (url, item) = try media()
        let model = PlaybackModel()
        model.open(url, item: item, rate: 1, muted: false) {}
        let player = try XCTUnwrap(model.player)
        model.stop()
        XCTAssertNil(model.player)
        XCTAssertNil(model.mediaID)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
    }
}
