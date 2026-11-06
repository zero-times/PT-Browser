import XCTest
@testable import PTBrowser

final class LibraryPresentationTests: XCTestCase {
    private func media(_ name: String, kind: MediaKind, date: Date) -> MediaItem {
        MediaItem(id: name, name: name, relativePath: name, kind: kind, bytes: 0, created: date, parts: [])
    }
    func testHiddenMediaTypeFilters() {
        let items = [media("image", kind: .image, date: .now), media("video", kind: .video, date: .now), media("audio", kind: .audio, date: .now)]
        XCTAssertEqual(items.filter(LibraryMediaFilter.all.includes).count, 3)
        XCTAssertEqual(items.filter(LibraryMediaFilter.image.includes).map(\.name), ["image"])
        XCTAssertEqual(items.filter(LibraryMediaFilter.video.includes).map(\.name), ["video"])
        XCTAssertEqual(items.filter(LibraryMediaFilter.audio.includes).map(\.name), ["audio"])
        XCTAssertTrue(LibraryDateGroup.sections([]).isEmpty)
    }
    func testDateGroupsUseLocalDayAndPreserveOrderWithinDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let formatter = ISO8601DateFormatter()
        let dates = try ["2026-10-20T16:01:00Z", "2026-10-20T15:59:00Z", "2026-10-21T02:00:00Z"].map { try XCTUnwrap(formatter.date(from: $0)) }
        let items = [media("A", kind: .image, date: dates[0]), media("B", kind: .video, date: dates[1]), media("C", kind: .image, date: dates[2])]
        let groups = LibraryDateGroup.sections(items, calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].items.map(\.name), ["A", "C"])
        XCTAssertEqual(groups[1].items.map(\.name), ["B"])
        XCTAssertGreaterThan(groups[0].day, groups[1].day)
        let images = LibraryDateGroup.sections(items.filter(LibraryMediaFilter.image.includes), calendar: calendar)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.flatMap(\.items).map(\.id), ["A", "C"])
    }
}
