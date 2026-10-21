import XCTest
@testable import PTBrowser

@MainActor final class DownloadHistoryTests: XCTestCase {
    func testOneTapClearKeepsActiveTasksAndSavedMediaAndPersistsTheQueue() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = root.appendingPathComponent("Queue")
        try fm.createDirectory(at: queue, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let saved = root.appendingPathComponent("SavedVideo.mp4")
        let bytes = Data("already-saved-media".utf8)
        try bytes.write(to: saved)
        let partial = queue.appendingPathComponent("failed-download.mp4")
        try Data("partial".utf8).write(to: partial)
        let states: [DownloadJob.State] = [.preparing, .running, .paused, .verifying, .completed, .failed, .cancelled]
        let jobs = states.map { state in
            DownloadJob(id: UUID(), url: URL(string: "https://example.invalid/video.mp4")!, name: "\(state.rawValue).mp4", kind: .video, isHLS: false, page: nil, state: state, destination: Data(), destinationName: "Files")
        }
        var fixture = jobs
        fixture[5].incoming = partial
        // Even a damaged old record must never delete a saved media file outside queue storage.
        fixture[4].incoming = saved
        try JSONEncoder().encode(fixture).write(to: queue.appendingPathComponent("queue.json"))
        let center = DownloadCenter(configuration: .ephemeral, storageDirectory: queue)
        XCTAssertTrue(center.canClearHistory)
        center.clearHistory()
        XCTAssertEqual(Set(center.jobs.map(\.id)), Set(jobs.prefix(4).map(\.id)))
        XCTAssertFalse(center.canClearHistory)
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        let persisted = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: queue.appendingPathComponent("queue.json")))
        XCTAssertEqual(Set(persisted.map(\.id)), Set(jobs.prefix(4).map(\.id)))
        // A second tap is harmless and cannot remove paused/preparing/verifying tasks.
        center.clearHistory()
        XCTAssertEqual(center.jobs.count, 4)
    }
}
