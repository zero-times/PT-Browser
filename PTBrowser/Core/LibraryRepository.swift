import Foundation
import CryptoKit

/// All filesystem and cryptographic work is serialized off the UI actor.
actor LibraryRepository {
    let root: URL
    private let fm = FileManager.default
    private var coordinatedRoot: URL?
    private var activeRoot: URL { coordinatedRoot ?? root }
    private var envelope: VaultEnvelope?
    private var key: SymmetricKey?
    private var privateItems: [MediaItem] = []
    private var publicIndex = PublicIndex()
    private let cache: URL
    private var meta: URL { activeRoot.appendingPathComponent(".ptbrowser", isDirectory: true) }
    private var vault: URL { meta.appendingPathComponent("vault.json") }
    private var dataRoot: URL { meta.appendingPathComponent("encrypted", isDirectory: true) }

    init(root: URL) {
        self.root = root
        self.cache = FileManager.default.temporaryDirectory.appendingPathComponent("PTDecrypted/\(UUID().uuidString)", isDirectory: true)
    }

    private func coordinate<T>(write: Bool = false, reading source: URL? = nil, _ body: (URL?) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        let granted = root.startAccessingSecurityScopedResource()
        defer { if granted { root.stopAccessingSecurityScopedResource() } }
        func access(_ directory: URL, _ readable: URL?) {
            let previous = coordinatedRoot
            coordinatedRoot = directory
            defer { coordinatedRoot = previous }
            result = Result {
                try validateInternalPaths()
                if write { try synchronizeIndexes() }
                return try body(readable)
            }
        }
        if write, let source {
            coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: root, options: .forMerging, error: &coordinationError) { readable, directory in access(directory, readable) }
        } else if write {
            coordinator.coordinate(writingItemAt: root, options: .forMerging, error: &coordinationError) { access($0, nil) }
        } else {
            coordinator.coordinate(readingItemAt: root, options: [], error: &coordinationError) { access($0, nil) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PTError.message("Files 文件夹暂时不可用，请检查文件提供商或重新选择文件夹") }
        return try result.get()
    }

    private func validateInternalPaths() throws {
        for url in [meta, dataRoot, vault, meta.appendingPathComponent("library.json")] {
            _ = try LibraryPaths.relativePath(of: url, inside: activeRoot)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw PTError.message("文件库元数据不允许使用符号链接") }
        }
    }

    /// Coordinate and reload before writes so two installations cannot silently lose index entries.
    private func synchronizeIndexes() throws {
        let publicFile = meta.appendingPathComponent("library.json")
        if fm.fileExists(atPath: publicFile.path) {
            let current = try JSONDecoder().decode(PublicIndex.self, from: Data(contentsOf: publicFile))
            guard current.version == 1 else { throw PTError.message("普通文件索引版本不受支持") }
            publicIndex = current
        }
        if fm.fileExists(atPath: vault.path) {
            let current = try JSONDecoder().decode(VaultEnvelope.self, from: Data(contentsOf: vault))
            if current.index != envelope?.index || current.id != envelope?.id {
                if let key, current.salt == envelope?.salt, current.id == envelope?.id, current.rounds == envelope?.rounds {
                    privateItems = try VaultCrypto.openIndex(current, key: key)
                } else { key = nil; privateItems = [] }
                purgeCache()
            }
            envelope = current
        } else if envelope != nil { envelope = nil; key = nil; privateItems = []; purgeCache() }
    }

    private func prepare() throws {
        try validateInternalPaths()
        try fm.createDirectory(at: meta, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func savePublic() throws { try writeJSON(publicIndex, to: meta.appendingPathComponent("library.json")) }

    private func savePrivate(_ items: [MediaItem]) throws {
        guard var updated = envelope, let key else { throw PTError.message("请先解锁加密库") }
        updated.index = try VaultCrypto.sealIndex(items, key: key, vaultID: updated.id)
        try writeJSON(updated, to: vault)
        envelope = updated
        privateItems = items
    }

    static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty || $0 == ".ptbrowser" })
    }

    private func publicURL(_ path: String) throws -> URL {
        guard Self.validRelativePath(path) else { throw PTError.message("文件路径不合法") }
        let candidate = activeRoot.appendingPathComponent(path).standardizedFileURL
        _ = try LibraryPaths.relativePath(of: candidate, inside: activeRoot)
        return candidate
    }

    private func uniqueURL(name: String, folder: String = "") throws -> URL {
        let parent = folder.isEmpty ? activeRoot : try publicURL(folder)
        let safe = name.safeFilename
        guard !safe.hasPrefix(".") else { throw PTError.message("文件名称不能以点开头") }
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = parent.appendingPathComponent(safe)
        var count = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) (\(count))" + (ext.isEmpty ? "" : ".\(ext)"))
            count += 1
        }
        _ = try publicURL(relative(candidate))
        return candidate
    }

    private func relative(_ url: URL) throws -> String { try LibraryPaths.relativePath(of: url, inside: activeRoot) }

    func snapshot() throws -> LibrarySnapshot {
        try coordinate(write: true) { _ in
            try prepare()
            let publicFile = meta.appendingPathComponent("library.json")
            if fm.fileExists(atPath: publicFile.path) { publicIndex = try JSONDecoder().decode(PublicIndex.self, from: Data(contentsOf: publicFile)) }
            if fm.fileExists(atPath: vault.path) {
                let disk = try JSONDecoder().decode(VaultEnvelope.self, from: Data(contentsOf: vault))
                if let previous = envelope, previous.index != disk.index { key = nil; privateItems = []; purgeCache() }
                envelope = disk
            } else { envelope = nil; key = nil; privateItems = []; purgeCache() }
            var records: [String: MediaItem] = [:]
            var folders: [String] = []
            guard let scanner = fm.enumerator(at: LibraryPaths.canonical(activeRoot), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey], options: [.skipsHiddenFiles]) else { throw PTError.message("无法读取该文件夹") }
            for case let file as URL in scanner {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey])
                if values.isSymbolicLink == true { scanner.skipDescendants(); continue }
                let path = try relative(file)
                guard Self.validRelativePath(path) else { scanner.skipDescendants(); continue }
                let isPackage = file.pathExtension.lowercased() == "movpkg"
                if values.isDirectory == true && !isPackage { folders.append(path); continue }
                if isPackage { scanner.skipDescendants() }
                guard let kind = MediaKind.detect(file) else { continue }
                // Repair indexes written by the old string-slicing implementation.
                // The physical file is authoritative; preserve its existing ID/favorite/hash.
                let legacyPath = String(file.path.dropFirst(root.path.count + 1))
                var item = publicIndex.records[path] ?? publicIndex.records[legacyPath] ?? MediaItem(id: UUID().uuidString, name: file.lastPathComponent, relativePath: path, kind: kind, bytes: 0, created: values.creationDate ?? Date())
                let bytes = isPackage ? try folderBytes(file) : Int64(values.fileSize ?? 0)
                if UUID(uuidString: item.id) == nil { item.id = UUID().uuidString }
                item.relativePath = path
                item.parts = nil
                item.bytes = bytes
                item.name = file.lastPathComponent
                item.kind = kind
                item.isPackage = isPackage
                records[path] = item
            }
            publicIndex.records = records
            try savePublic()
            return LibrarySnapshot(items: Array(records.values) + privateItems, folders: folders.sorted(), hasVault: envelope != nil, unlocked: key != nil)
        }
    }

    private func folderBytes(_ url: URL) throws -> Int64 {
        let paths = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
        var total: Int64 = 0
        while let file = paths?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    func createVault(password: String) throws {
        guard password.count >= 8 else { throw PTError.message("请使用至少 8 个字符的密码") }
        try coordinate(write: true) { _ in
            try prepare()
            guard !fm.fileExists(atPath: vault.path) else { throw PTError.message("此文件夹已有加密库，请使用原密码解锁") }
            let salt = try VaultCrypto.randomSalt()
            let derived = try VaultCrypto.derive(password: password, salt: salt, rounds: VaultCrypto.rounds)
            let id = UUID().uuidString
            let created = VaultEnvelope(id: id, salt: salt, rounds: VaultCrypto.rounds, index: try VaultCrypto.sealIndex([], key: derived, vaultID: id))
            try writeJSON(created, to: vault)
            envelope = created
            key = derived
            privateItems = []
        }
    }

    func unlock(password: String) throws {
        try coordinate { _ in
            let disk = try JSONDecoder().decode(VaultEnvelope.self, from: Data(contentsOf: vault))
            let derived = try VaultCrypto.derive(password: password, salt: disk.salt, rounds: disk.rounds)
            let items = try VaultCrypto.openIndex(disk, key: derived)
            guard items.allSatisfy({ UUID(uuidString: $0.id) != nil && Self.validRelativePath($0.relativePath) && ($0.parts ?? []).allSatisfy { Self.validRelativePath($0.path) && UUID(uuidString: $0.blob) != nil } }) else { throw PTError.message("加密索引路径校验失败") }
            envelope = disk
            key = derived
            privateItems = items
        }
    }

    func lock() { key = nil; privateItems = []; purgeCache() }
    private func purgeCache() { try? fm.removeItem(at: cache) }

    func importFile(_ source: URL, folder: String = "", preferredName: String? = nil, expectedSHA256: String? = nil) throws -> MediaItem {
        try coordinate(write: true, reading: source) { readable in
            try prepare()
            let destination = try uniqueURL(name: preferredName ?? source.lastPathComponent, folder: folder)
            guard let kind = MediaKind.detect(destination) else { throw PTError.message("暂不支持此文件类型") }
            let package = destination.pathExtension == "movpkg"
            let staging = meta.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: readable ?? source, to: staging)
            let hash = package ? nil : try VaultCrypto.hash(staging)
            if let expectedSHA256, hash != expectedSHA256.lowercased() { throw PTError.message("SHA-256 与预期不一致，文件未导入") }
            let bytes = package ? try folderBytes(staging) : Int64(try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            try fm.moveItem(at: staging, to: destination)
            let item = MediaItem(id: UUID().uuidString, name: destination.lastPathComponent, relativePath: try relative(destination), kind: kind, bytes: bytes, created: Date(), sha256: hash, isPackage: package)
            publicIndex.records[item.relativePath] = item
            try savePublic()
            return item
        }
    }

    func createFolder(_ name: String, parent: String = "") throws {
        try coordinate(write: true) { _ in try fm.createDirectory(at: uniqueURL(name: name, folder: parent), withIntermediateDirectories: false) }
    }

    func favorite(_ item: MediaItem) throws {
        try coordinate(write: true) { _ in
            if item.isEncrypted {
                var items = privateItems
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { throw PTError.message("请先解锁加密库") }
                items[index].favorite.toggle()
                try savePrivate(items)
            } else if var current = publicIndex.records[item.relativePath] {
                current.favorite.toggle(); publicIndex.records[item.relativePath] = current; try savePublic()
            }
        }
    }

    func rename(_ item: MediaItem, name: String, folder: String? = nil) throws {
        try coordinate(write: true) { _ in
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PTError.message("请输入名称") }
            let ext = (item.name as NSString).pathExtension
            let filename = (name as NSString).pathExtension == ext ? name : name + (ext.isEmpty ? "" : "." + ext)
            if item.isEncrypted {
                var items = privateItems
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { throw PTError.message("请先解锁加密库") }
                items[index].name = filename.safeFilename
                try savePrivate(items)
            } else {
                if filename.safeFilename == item.name && (folder ?? item.folder) == item.folder { return }
                let source = try publicURL(item.relativePath)
                let destination = try uniqueURL(name: filename, folder: folder ?? item.folder)
                try fm.moveItem(at: source, to: destination)
                var updated = publicIndex.records[item.relativePath] ?? item
                updated.name = destination.lastPathComponent; updated.relativePath = try relative(destination)
                publicIndex.records.removeValue(forKey: item.relativePath)
                publicIndex.records[updated.relativePath] = updated
                try savePublic()
            }
        }
    }

    func delete(_ item: MediaItem) throws {
        try coordinate(write: true) { _ in
            if item.isEncrypted {
                guard key != nil, privateItems.contains(where: { $0.id == item.id }) else { throw PTError.message("请先解锁加密库") }
                let source = dataRoot.appendingPathComponent(item.id)
                let trash = meta.appendingPathComponent("deleting-" + UUID().uuidString)
                try fm.moveItem(at: source, to: trash)
                do { try savePrivate(privateItems.filter { $0.id != item.id }) }
                catch { try? fm.moveItem(at: trash, to: source); throw error }
                try fm.removeItem(at: trash)
            } else {
                try fm.removeItem(at: publicURL(item.relativePath))
                publicIndex.records.removeValue(forKey: item.relativePath); try savePublic()
            }
            try? fm.removeItem(at: cache.appendingPathComponent(item.id))
        }
    }

    func encrypt(_ item: MediaItem) throws {
        guard !item.isEncrypted else { throw PTError.message("文件已经加密") }
        let requested = try publicURL(item.relativePath)
        try coordinate(write: true, reading: requested) { readable in
            guard let key, let envelope else { throw PTError.message("请先创建或解锁加密库") }
            let source = readable ?? requested
            _ = try LibraryPaths.relativePath(of: source, inside: activeRoot)
            let staging = meta.appendingPathComponent("stage-\(UUID().uuidString)")
            let destination = dataRoot.appendingPathComponent(item.id)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            var sources: [(String, URL)] = []
            if item.isPackage {
                let scan = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                while let file = scan?.nextObject() as? URL {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw PTError.message("媒体包包含不支持的符号链接") }
                    if values.isRegularFile == true { sources.append((try LibraryPaths.relativePath(of: file, inside: source), file)) }
                }
            } else { sources = [(item.name, source)] }
            guard !sources.isEmpty else { throw PTError.message("媒体包为空") }
            var parts: [ProtectedPart] = []
            for (path, file) in sources {
                guard Self.validRelativePath(path) else { throw PTError.message("媒体包路径无效") }
                let blob = UUID().uuidString
                let (size, hash) = try VaultCrypto.encrypt(source: file, destination: staging.appendingPathComponent(blob + ".ptenc"), key: key, identity: envelope.id + item.id + blob)
                parts.append(ProtectedPart(path: path, blob: blob, bytes: size, sha256: hash))
            }
            if fm.fileExists(atPath: destination.path) { throw PTError.message("存在未完成的同名加密操作，请刷新后重试") }
            try fm.moveItem(at: staging, to: destination)
            var hidden = publicIndex.records[item.relativePath] ?? item; hidden.parts = parts
            do { try savePrivate(privateItems + [hidden]) }
            catch { try? fm.removeItem(at: destination); throw error }
            // Never remove the original before the authenticated index has committed.
            publicIndex.records.removeValue(forKey: item.relativePath)
            try savePublic()
            try fm.removeItem(at: source)
        }
    }

    func playableURL(_ item: MediaItem) throws -> URL {
        if !item.isEncrypted {
            let file = try publicURL(item.relativePath)
            var error: NSError?
            var result: URL?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { result = $0 }
            if let error { throw error }
            guard let result, fm.fileExists(atPath: result.path) else { throw PTError.message("文件尚未下载或已被移走，请在 Files 中检查") }
            return result
        }
        guard let key, let envelope, let current = privateItems.first(where: { $0.id == item.id }), let parts = current.parts else { throw PTError.message("加密库已锁定") }
        return try coordinate { _ in
            let parent = cache.appendingPathComponent(item.id)
            let output = parent.appendingPathComponent(item.isPackage ? "media.movpkg" : "media." + (item.name as NSString).pathExtension)
            if fm.fileExists(atPath: output.path) { return output }
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var success = false
            defer { if !success { try? fm.removeItem(at: parent) } }
            if item.isPackage { try fm.createDirectory(at: output, withIntermediateDirectories: true) }
            for part in parts {
                let target = item.isPackage ? output.appendingPathComponent(part.path) : output
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try VaultCrypto.decrypt(source: dataRoot.appendingPathComponent(item.id).appendingPathComponent(part.blob + ".ptenc"), destination: target, key: key, identity: envelope.id + item.id + part.blob, expectedBytes: part.bytes, expectedHash: part.sha256)
            }
            success = true
            return output
        }
    }

    func restore(_ item: MediaItem, folder: String = "") throws {
        let clear = try playableURL(item)
        try coordinate(write: true) { _ in
            guard key != nil, privateItems.contains(where: { $0.id == item.id }) else { throw PTError.message("加密库已锁定或媒体已被移走") }
            let destination = try uniqueURL(name: item.name, folder: folder)
            try fm.copyItem(at: clear, to: destination)
            let original = privateItems.first(where: { $0.id == item.id }) ?? item
            do { try savePrivate(privateItems.filter { $0.id != item.id }) }
            catch { try? fm.removeItem(at: destination); throw error }
            var restored = original; restored.parts = nil; restored.relativePath = try relative(destination); restored.name = destination.lastPathComponent
            publicIndex.records[restored.relativePath] = restored
            try savePublic()
            try fm.removeItem(at: dataRoot.appendingPathComponent(item.id))
            try? fm.removeItem(at: cache.appendingPathComponent(item.id))
        }
    }

    func verify(_ item: MediaItem) throws -> String {
        if item.isEncrypted {
            try? fm.removeItem(at: cache.appendingPathComponent(item.id))
            _ = try playableURL(item)
            return "所有加密数据块和 SHA-256 校验通过"
        }
        let requested = try publicURL(item.relativePath)
        return try coordinate(write: true, reading: requested) { readable in
            if item.isPackage { throw PTError.message("离线 HLS 包由系统管理；播放时由 AVFoundation 检查可用性") }
            let hash = try VaultCrypto.hash(readable ?? requested)
            if let expected = item.sha256, expected != hash { throw PTError.message("SHA-256 不一致：文件在导入后发生了变化") }
            var updated = item; updated.sha256 = hash; publicIndex.records[item.relativePath] = updated; try savePublic()
            return "SHA-256\n\(hash)"
        }
    }

}
