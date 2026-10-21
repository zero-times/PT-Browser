import Foundation
import WebKit
import AVFoundation
import UIKit

struct DownloadJob: Codable, Identifiable {
    enum State: String, Codable {
        case preparing, running, paused, verifying, completed, failed, cancelled
        var isHistory: Bool { self == .completed || self == .failed || self == .cancelled }
    }
    var id: UUID
    var url: URL
    var name: String
    var kind: MediaKind
    var isHLS: Bool
    var page: URL?
    var state: State
    var received: Int64 = 0
    var expected: Int64 = 0
    var progress: Double = 0
    var message: String?
    var sha256: String?
    var expectedSHA256: String?
    var destination: Data
    var destinationName: String
    var resumeData: Data?
    var incoming: URL?
    var headers: [String: String] = [:]
    var preferredTitle: String?
    var created = Date()
    var finished: Date?
}

@MainActor
final class DownloadCenter: NSObject, ObservableObject, @preconcurrency URLSessionDownloadDelegate, @preconcurrency AVAssetDownloadDelegate {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var error: String?
    weak var library: LibraryStore?
    private let fm = FileManager.default
    private var tasks: [UUID: URLSessionTask] = [:]
    private var expectedPauses = Set<UUID>()
    private var completions: [String: () -> Void] = [:]
    private var finishedEvents = Set<String>()
    private var finalizing = Set<UUID>()
    private let injectedConfiguration: URLSessionConfiguration?
    private let injectedSupport: URL?
    private var sessionSuffix: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitesting") { return ".uitesting" }
        #endif
        return ""
    }
    private var restoredSessions = 0
    private var restoringIDs = Set<UUID>()
    private lazy var plainSession: URLSession = {
        let config = injectedConfiguration ?? URLSessionConfiguration.background(withIdentifier: Bundle.main.bundleIdentifier! + ".media-downloads" + sessionSuffix)
        config.httpMaximumConnectionsPerHost = 3
        if config.identifier != nil { config.sessionSendsLaunchEvents = true }
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Bundle.main.bundleIdentifier! + ".hls-downloads" + sessionSuffix)
        config.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()
    private var support: URL { injectedSupport ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true) }
    private var stateFile: URL { support.appendingPathComponent("queue.json") }

    init(configuration: URLSessionConfiguration? = nil, storageDirectory: URL? = nil) {
        injectedConfiguration = configuration
        #if DEBUG
        if storageDirectory == nil && configuration == nil && ProcessInfo.processInfo.arguments.contains("-uitesting") {
            let disposable = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UITestDownloads", isDirectory: true)
            try? FileManager.default.removeItem(at: disposable)
            injectedSupport = disposable
        } else { injectedSupport = storageDirectory }
        #else
        injectedSupport = storageDirectory
        #endif
        super.init()
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateFile), let saved = try? JSONDecoder().decode([DownloadJob].self, from: data) { jobs = saved }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitesting") && ProcessInfo.processInfo.arguments.contains("-history-ui-fixtures") {
            jobs = UITestMediaFixtures.downloadHistory(); save()
        }
        #endif
        plainSession.getAllTasks { [weak self] tasks in Task { @MainActor in self?.restore(tasks) } }
        if configuration == nil { hlsSession.getAllTasks { [weak self] tasks in Task { @MainActor in self?.restore(tasks) } } }
        else { restore([]) }
        NotificationCenter.default.addObserver(forName: .backgroundDownloadEvents, object: nil, queue: .main) { [weak self] notification in
            if let handler = notification.object as? BackgroundCompletion { Task { @MainActor in guard let self else { return }; self.completions[handler.identifier] = handler.handler; self.flushBackgroundCompletions() } }
        }
    }

    private func restore(_ restored: [URLSessionTask]) {
        for task in restored {
            if let description = task.taskDescription, let id = UUID(uuidString: description), jobs.contains(where: { $0.id == id }) { tasks[id] = task; restoringIDs.insert(id) }
            else { task.cancel() }
        }
        restoredSessions += 1
        if restoredSessions == 2 {
            for index in jobs.indices where [.preparing, .running, .verifying].contains(jobs[index].state) && tasks[jobs[index].id] == nil {
                if let incoming = jobs[index].incoming, fm.fileExists(atPath: incoming.path) { jobs[index].state = .paused; jobs[index].message = "下载已完成，点击继续执行导入校验" }
                else { jobs[index].state = .failed; jobs[index].message = "上次任务已中断，可重试" }
            }
            save()
        }
    }

    private func save() {
        do { try JSONEncoder().encode(jobs).write(to: stateFile, options: [.atomic, .completeFileProtection]) }
        catch { self.error = "无法保存下载队列：\(error.localizedDescription)" }
    }

    func enqueue(_ candidate: MediaCandidate, tab: BrowserTab?, expectedSHA256: String? = nil) async {
        guard let library, ["http", "https"].contains(candidate.url.scheme?.lowercased() ?? ""), candidate.url.host != nil else { error = "请输入有效的 HTTP / HTTPS 媒体地址"; return }
        if jobs.contains(where: { $0.url == candidate.url && [.preparing, .running, .verifying].contains($0.state) }) { error = "该资源已在下载队列中"; return }
        do {
            let bookmark = try library.root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let id = UUID()
            let title = candidate.preferredTitle ?? MediaNaming.title(tab?.webView.title)
            let filename = MediaNaming.filename(title: title, kind: candidate.kind, url: candidate.url, mime: candidate.mime, isHLS: candidate.isHLS)
            var job = DownloadJob(id: id, url: candidate.url, name: filename, kind: candidate.kind, isHLS: candidate.isHLS, page: candidate.page, state: .preparing, expectedSHA256: expectedSHA256?.isEmpty == false ? expectedSHA256?.lowercased() : nil, destination: bookmark, destinationName: library.root.lastPathComponent)
            job.preferredTitle = title
            jobs.insert(job, at: 0); save()
            let cookies = await tab?.webView.configuration.websiteDataStore.httpCookieStore.allCookies() ?? []
            let relevant = cookies.filter { cookie in
                let host = candidate.url.host?.lowercased() ?? ""
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let path = candidate.url.path.isEmpty ? "/" : candidate.url.path
                return (host == domain || host.hasSuffix("." + domain)) && (path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")) && (!cookie.isSecure || candidate.url.scheme == "https") && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
            }
            job.headers = HTTPCookie.requestHeaderFields(with: relevant)
            if let referer = candidate.page { job.headers["Referer"] = referer.absoluteString }
            if let userAgent = try? await tab?.webView.evaluateJavaScript("navigator.userAgent") as? String { job.headers["User-Agent"] = userAgent }
            // A cancelled preparing task must never start later after cookie retrieval.
            guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .preparing else { return }
            jobs[index].headers = job.headers
            start(id)
        } catch { self.error = error.localizedDescription }
    }

    private func start(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs[index]
        let task: URLSessionTask
        if job.isHLS {
            var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": job.headers]
            if let agent = job.headers["User-Agent"] { options[AVURLAssetHTTPUserAgentKey] = agent }
            let asset = AVURLAsset(url: job.url, options: options)
            guard let download = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: job.name, assetArtworkData: nil, options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 0]) else { fail(id, "无法建立 HLS 离线任务"); return }
            task = download
        } else if let resume = job.resumeData {
            task = plainSession.downloadTask(withResumeData: resume)
        } else {
            var request = URLRequest(url: job.url)
            request.allHTTPHeaderFields = job.headers
            request.timeoutInterval = 60
            task = plainSession.downloadTask(with: request)
        }
        task.taskDescription = id.uuidString
        tasks[id] = task
        jobs[index].state = .running; jobs[index].message = nil; jobs[index].resumeData = nil
        task.resume(); save()
    }

    func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), let task = tasks[id] else { return }
        jobs[index].state = .paused
        if let task = task as? URLSessionDownloadTask {
            expectedPauses.insert(id)
            task.cancel { [weak self] resume in
                Task { @MainActor in
                    guard let self, let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].state == .paused else { return }
                    self.jobs[i].resumeData = resume; self.save()
                }
            }
        } else { task.suspend() }
        save()
    }

    func resume(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), ![.running, .verifying].contains(jobs[index].state) else { return }
        if let incoming = jobs[index].incoming, fm.fileExists(atPath: incoming.path) { Task { await finish(id) }; return }
        if let task = tasks[id], task.state == .suspended { task.resume(); jobs[index].state = .running; save() }
        else { start(id) }
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .verifying else { return }
        jobs[index].state = .cancelled; jobs[index].resumeData = nil; jobs[index].headers = [:]
        tasks[id]?.cancel(); tasks.removeValue(forKey: id)
        if let incoming = jobs[index].incoming { try? fm.removeItem(at: incoming) }
        jobs[index].incoming = nil
        save()
    }
    func remove(_ id: UUID) { cancel(id); jobs.removeAll { $0.id == id && $0.state != .verifying }; save() }
    var canClearHistory: Bool { jobs.contains { $0.state.isHistory } }

    func clearHistory() {
        let history = jobs.filter { $0.state.isHistory }
        guard !history.isEmpty else { return }
        // Remove records before cancelling tasks so late delegate callbacks cannot re-import them.
        jobs.removeAll { $0.state.isHistory }
        for job in history {
            tasks.removeValue(forKey: job.id)?.cancel()
            expectedPauses.remove(job.id)
            if let incoming = job.incoming,
               (try? LibraryPaths.relativePath(of: incoming, inside: support)) != nil {
                try? fm.removeItem(at: incoming)
            }
        }
        save()
    }

    private func fail(_ id: UUID, _ text: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .cancelled else { return }
        jobs[index].state = .failed; jobs[index].message = text; save()
    }
    private func id(_ task: URLSessionTask) -> UUID? { task.taskDescription.flatMap(UUID.init(uuidString:)) }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = id(downloadTask), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].received = totalBytesWritten; jobs[index].expected = totalBytesExpectedToWrite
        jobs[index].progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = id(downloadTask), let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .cancelled else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw PTError.message("服务器返回 HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)") }
            guard response.mimeType?.contains("text/html") != true, response.mimeType?.contains("application/json") != true else { throw PTError.message("服务器返回了网页或 JSON，可能需要登录或原链接已失效") }
            let actualLength = Int64(try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard response.expectedContentLength <= 0 || response.expectedContentLength == actualLength || response.value(forHTTPHeaderField: "Content-Encoding") != nil else { throw PTError.message("下载长度与服务器声明不一致") }
            let finalName = MediaNaming.filename(title: jobs[index].preferredTitle, kind: jobs[index].kind, url: jobs[index].url, mime: response.mimeType, suggestedFilename: response.suggestedFilename)
            let incoming = support.appendingPathComponent(id.uuidString + "." + (finalName as NSString).pathExtension)
            if fm.fileExists(atPath: incoming.path) { try fm.removeItem(at: incoming) }
            try fm.moveItem(at: location, to: incoming)
            jobs[index].name = finalName; jobs[index].incoming = incoming
            jobs[index].kind = MediaKind.detect(incoming, mime: response.mimeType) ?? jobs[index].kind
            save()
        } catch { fail(id, error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = id(assetDownloadTask), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let total = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + CMTimeGetSeconds($1.timeRangeValue.duration) }
        jobs[index].progress = total > 0 ? min(loaded / total, 1) : 0
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = id(assetDownloadTask), let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .cancelled else { return }
        do {
            let incoming = support.appendingPathComponent(id.uuidString + ".movpkg")
            if fm.fileExists(atPath: incoming.path) { try fm.removeItem(at: incoming) }
            try fm.copyItem(at: location, to: incoming)
            jobs[index].incoming = incoming
            jobs[index].name = MediaNaming.filename(title: jobs[index].preferredTitle, kind: jobs[index].kind, url: jobs[index].url, suggestedFilename: jobs[index].name, isHLS: true)
            save()
            try? fm.removeItem(at: location)
        } catch { fail(id, error.localizedDescription) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = id(task), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if expectedPauses.remove(id) != nil { if tasks[id] === task { tasks.removeValue(forKey: id) }; return }
        if tasks[id] === task { tasks.removeValue(forKey: id) }
        guard jobs[index].state != .cancelled, jobs[index].state != .failed else { return }
        if let error {
            if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { jobs[index].resumeData = resume }
            fail(id, error.localizedDescription)
        } else if jobs[index].incoming != nil { finalizing.insert(id); Task { await finish(id) } }
        else { fail(id, "传输已结束但没有可导入的文件，请重试") }
    }

    private func finish(_ id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }), let incoming = jobs[index].incoming, jobs[index].state != .verifying else { return }
        let job = jobs[index]
        finalizing.insert(id)
        defer { finalizing.remove(id); flushBackgroundCompletions() }
        jobs[index].state = .verifying; jobs[index].message = "正在校验并保存至 Files"; save()
        var validated = false
        do {
            if !job.isHLS {
                if job.kind == .image {
                    guard let source = CGImageSourceCreateWithURL(incoming as CFURL, nil), CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil else { throw PTError.message("文件不是可解码的图片，已阻止导入") }
                } else {
                    guard try await AVURLAsset(url: incoming).load(.isPlayable) else { throw PTError.message("媒体无法播放，可能已损坏或格式不受 iOS 支持") }
                }
            } else if let expected = job.expectedSHA256, !expected.isEmpty { throw PTError.message("HLS 为目录包，不能使用单文件 SHA-256；请移除此校验值后重试") }
            validated = true
            var stale = false
            let folder = try URL(resolvingBookmarkData: job.destination, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let repository: LibraryRepository
            if let library, LibraryPaths.sameDirectory(library.root, folder) { repository = library.repository }
            else { repository = LibraryRepository(root: folder); _ = try await repository.snapshot() }
            let imported = try await repository.importFile(incoming, preferredName: job.name, expectedSHA256: job.expectedSHA256)
            try? fm.removeItem(at: incoming)
            if let updated = jobs.firstIndex(where: { $0.id == id }) {
                jobs[updated].name = imported.name
                jobs[updated].state = .completed; jobs[updated].progress = 1; jobs[updated].message = "已保存至 \(job.destinationName)"; jobs[updated].sha256 = imported.sha256
                jobs[updated].headers = [:]; jobs[updated].resumeData = nil; jobs[updated].incoming = nil; jobs[updated].finished = Date()
            }
            await library?.refresh(); save()
        } catch {
            if !validated || error.localizedDescription.contains("SHA-256 与预期") {
                try? fm.removeItem(at: incoming)
                if let updated = jobs.firstIndex(where: { $0.id == id }) { jobs[updated].incoming = nil }
            }
            fail(id, error.localizedDescription)
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let identifier = session.configuration.identifier { finishedEvents.insert(identifier) }
        flushBackgroundCompletions()
    }
    private func flushBackgroundCompletions() {
        guard finalizing.isEmpty else { return }
        for identifier in Array(finishedEvents) {
            if let callback = completions.removeValue(forKey: identifier) { finishedEvents.remove(identifier); callback() }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var safe = request
        if response.url?.host?.lowercased() != request.url?.host?.lowercased() {
            safe.setValue(nil, forHTTPHeaderField: "Cookie")
            safe.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        if response.url?.scheme == "https" && request.url?.scheme == "http" { safe.setValue(nil, forHTTPHeaderField: "Referer") }
        completionHandler(safe)
    }
}

import UniformTypeIdentifiers
import ImageIO

extension Notification.Name { static let backgroundDownloadEvents = Notification.Name("PTBackgroundDownloadEvents") }
final class BackgroundCompletion { let identifier: String; let handler: () -> Void; init(identifier: String, _ handler: @escaping () -> Void) { self.identifier = identifier; self.handler = handler } }
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        NotificationCenter.default.post(name: .backgroundDownloadEvents, object: BackgroundCompletion(identifier: identifier, completionHandler))
    }
}
