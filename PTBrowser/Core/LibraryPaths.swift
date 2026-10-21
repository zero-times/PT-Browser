import Foundation

/// Files and directory enumeration may spell the same location differently (for
/// example /var and /private/var). Keep authorized URLs for I/O, compare resolved
/// components for containment, and never derive a relative path by character count.
enum LibraryPaths {
    static func canonical(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        // Foundation does not resolve ancestor symlinks when the final item does
        // not exist yet. Resolve the existing parent before appending new names.
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.pathComponents.count > 1 {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }

    static func relativePath(of file: URL, inside directory: URL) throws -> String {
        guard file.isFileURL, directory.isFileURL else { throw PTError.message("文件路径不合法") }
        let parent = canonical(directory).pathComponents
        let child = canonical(file).pathComponents
        guard child.count > parent.count, child.starts(with: parent) else {
            throw PTError.message("不允许访问文件库以外的路径")
        }
        let relative = child.dropFirst(parent.count).joined(separator: "/")
        return relative
    }

    static func sameDirectory(_ first: URL, _ second: URL) -> Bool {
        canonical(first).pathComponents == canonical(second).pathComponents
    }
}
