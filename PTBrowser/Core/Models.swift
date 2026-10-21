import Foundation
import UniformTypeIdentifiers

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio
    var title: String { switch self { case .image: "图片"; case .video: "视频"; case .audio: "音频" } }
    var icon: String { switch self { case .image: "photo"; case .video: "play.rectangle"; case .audio: "waveform" } }
    static func detect(_ url: URL, mime: String? = nil) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "movpkg" || ext == "m3u8" { return .video }
        let type = mime.flatMap { UTType(mimeType: $0.components(separatedBy: ";")[0]) } ?? UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { return .video }
        if type?.conforms(to: .audio) == true { return .audio }
        return nil
    }
}

struct ProtectedPart: Codable, Hashable, Sendable {
    var path: String
    var blob: String
    var bytes: Int64
    var sha256: String
}

struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var relativePath: String
    var kind: MediaKind
    var bytes: Int64
    var created: Date
    var favorite = false
    var sha256: String?
    var parts: [ProtectedPart]?
    var isPackage = false
    var isEncrypted: Bool { parts != nil }
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
    var byteLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct LibrarySnapshot: Sendable {
    var items: [MediaItem]
    var folders: [String]
    var hasVault: Bool
    var unlocked: Bool
}

struct VaultEnvelope: Codable, Sendable {
    var version = 1
    var id: String
    var salt: Data
    var rounds: UInt32
    var index: Data
}

struct PublicIndex: Codable {
    var version = 1
    var records: [String: MediaItem] = [:]
}

enum PTError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

extension String {
    var safeFilename: String {
        let cleaned = components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r")).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(180)).isEmpty ? "未命名" : String(cleaned.prefix(180))
    }
}
