import Foundation

enum LibraryMediaFilter: String, CaseIterable, Identifiable {
    case all, image, video, audio
    var id: Self { self }
    var title: String {
        switch self { case .all: "全部"; case .image: "图片"; case .video: "视频"; case .audio: "音频" }
    }
    func includes(_ item: MediaItem) -> Bool { self == .all || rawValue == item.kind.rawValue }
}

struct LibraryDateGroup: Identifiable {
    let day: Date
    let items: [MediaItem]
    var id: Date { day }
    /// Use the same creation/import date retained by encryption and decryption.
    /// Sort days newest first, preserving the selected sort within each day.
    static func sections(_ items: [MediaItem], calendar: Calendar = .current) -> [Self] {
        let groups = Dictionary(grouping: items) { calendar.startOfDay(for: $0.created) }
        return groups.keys.sorted(by: >).map { Self(day: $0, items: groups[$0] ?? []) }
    }
}
