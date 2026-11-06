import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot(items: [], folders: [], hasVault: false, unlocked: false)
    @Published private(set) var root: URL
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var privacyCovered = false
    @Published var generation = UUID()
    private(set) var repository: LibraryRepository
    private var scopedURL: URL?
    private var locking = false
    private var privacyEpoch = 0
    var publicItems: [MediaItem] { snapshot.items.filter { !$0.isEncrypted } }
    var privateItems: [MediaItem] { snapshot.items.filter(\.isEncrypted) }

    init() {
        let fm = FileManager.default
        // Decrypted working copies never survive a new process.
        try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("PTDecrypted"))
        let isTesting = ProcessInfo.processInfo.arguments.contains("-uitesting")
        var selected = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(isTesting ? "UITestLibrary" : "Media", isDirectory: true)
        if isTesting { try? fm.removeItem(at: selected) }
        if !isTesting, let data = UserDefaults.standard.data(forKey: "libraryBookmark") {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale), resolved.startAccessingSecurityScopedResource() {
                selected = resolved; scopedURL = resolved
                if stale, let renewed = try? resolved.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) { UserDefaults.standard.set(renewed, forKey: "libraryBookmark") }
            }
        }
        try? fm.createDirectory(at: selected, withIntermediateDirectories: true)
        #if DEBUG
        if isTesting && ProcessInfo.processInfo.arguments.contains("-media-ui-fixtures") { try? UITestMediaFixtures.seed(selected) }
        #endif
        root = selected
        repository = LibraryRepository(root: selected)
        Task {
            #if DEBUG
            if isTesting && ProcessInfo.processInfo.arguments.contains("-media-ui-fixtures") && ProcessInfo.processInfo.arguments.contains("-library-ui-fixtures") {
                do { try await UITestMediaFixtures.seedVault(repository) } catch { self.error = error.localizedDescription }
            }
            #endif
            await refresh()
        }
    }

    func refresh() async {
        let current = repository
        let epoch = privacyEpoch
        do {
            let result = try await current.snapshot()
            guard current === repository else { return }
            if epoch != privacyEpoch { snapshot = LibrarySnapshot(items: result.items.filter { !$0.isEncrypted }, folders: result.folders, hasVault: result.hasVault, unlocked: false) }
            else { snapshot = result }
        } catch { if snapshot.unlocked { lock() }; self.error = error.localizedDescription }
    }

    func perform(_ action: (LibraryRepository) async throws -> Void) async {
        guard !busy, !locking else { error = "另一项文件操作尚未结束，请稍后重试"; return }
        busy = true
        let current = repository
        do { try await action(current) } catch { self.error = error.localizedDescription }
        if current === repository { await refresh() }
        busy = false
    }

    func selectFolder(_ url: URL) async {
        guard !busy else { error = "请等待当前文件操作完成"; return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted && scopedURL != url { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let candidate = LibraryRepository(root: url)
            let result = try await candidate.snapshot()
            await repository.lock()
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = granted ? url : nil
            root = url; repository = candidate; snapshot = result; generation = UUID()
            UserDefaults.standard.set(bookmark, forKey: "libraryBookmark")
            notice = "已连接文件夹：\(url.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }

    func importFiles(_ urls: [URL], folder: String = "") async {
        await perform { repo in
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { _ = try await repo.importFile(url, folder: folder) }
                catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            if !failures.isEmpty { throw PTError.message(failures.joined(separator: "\n")) }
        }
    }

    func lock() {
        privacyEpoch += 1
        let wasUnlocked = snapshot.unlocked
        snapshot.items.removeAll { $0.isEncrypted }
        snapshot.unlocked = false
        if wasUnlocked { generation = UUID() }
        locking = true
        let current = repository
        Task { await current.lock(); locking = false }
    }

    func secureSessionBecameInactive() { privacyCovered = true; lock() }
}

struct FolderPicker: UIViewControllerRepresentable {
    var selected: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL) -> Void
        init(_ selected: @escaping (URL) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if let url = urls.first { selected(url) } }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
