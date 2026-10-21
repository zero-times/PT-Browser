import Foundation
import UniformTypeIdentifiers

/// The page supplies the human name; the response supplies the actual file type.
enum MediaNaming {
    static func title(_ value: String?) -> String? {
        guard let value else { return nil }
        let words = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let result = words.joined(separator: " ").trimmingCharacters(in: .controlCharacters)
        return result.isEmpty ? nil : String(result.prefix(500))
    }

    static func filename(title preferredTitle: String?, kind: MediaKind, url: URL, mime: String? = nil, suggestedFilename: String? = nil, isHLS: Bool = false) -> String {
        let responseType = mime.flatMap { UTType(mimeType: $0.components(separatedBy: ";")[0].lowercased()) }
        let mediaResponse = responseType.map { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) } ?? false
        let suggested = suggestedFilename.flatMap { title($0) }
        let resource = url.lastPathComponent.isEmpty ? "媒体资源" : url.lastPathComponent
        let fallback = suggested ?? resource
        let resourceExtension = [suggested, resource].compactMap { $0 }.first { name in
            MediaKind.detect(URL(fileURLWithPath: name)) != nil
        }.map { ($0 as NSString).pathExtension.lowercased() }
        let ext = isHLS ? "movpkg" : (mediaResponse ? responseType?.preferredFilenameExtension : nil) ?? resourceExtension ?? (kind == .image ? "jpg" : kind == .video ? "mp4" : "m4a")
        var stem = title(preferredTitle) ?? fallback
        // Preserve meaningful dots in titles such as “旅行 v1.2”; remove only a known media suffix.
        if MediaKind.detect(URL(fileURLWithPath: stem)) != nil || (stem as NSString).pathExtension.lowercased() == "movpkg" {
            stem = (stem as NSString).deletingPathExtension
        }
        stem = stem.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))).joined(separator: "_")
        stem = stem.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if stem.isEmpty { stem = "媒体资源" }
        // APFS limits names by UTF-8 bytes, not character count. Leave room for extensions and collision suffixes.
        var bounded = ""
        for character in stem {
            guard bounded.utf8.count + String(character).utf8.count <= 210 else { break }
            bounded.append(character)
        }
        return (bounded.isEmpty ? "媒体资源" : bounded) + "." + ext
    }
}
