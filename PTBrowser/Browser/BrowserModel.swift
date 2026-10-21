import SwiftUI
import WebKit

struct MediaCandidate: Identifiable, Hashable, Sendable {
    var url: URL
    var kind: MediaKind
    var source: String
    var page: URL?
    var width: Int = 0
    var height: Int = 0
    var mime: String?
    var mediaTitle: String?
    var pageTitle: String?
    var titlePriority: Int = 0
    var preferredTitle: String? { MediaNaming.title(mediaTitle) ?? MediaNaming.title(pageTitle) }
    var id: String { url.absoluteString }
    var name: String { preferredTitle ?? (url.lastPathComponent.isEmpty ? "媒体资源" : url.lastPathComponent) }
    var isHLS: Bool { url.pathExtension.lowercased() == "m3u8" || mime?.lowercased().contains("mpegurl") == true }
}

struct WebLink: Codable, Identifiable {
    var id = UUID()
    var title: String
    var url: URL
    var date = Date()
}

private final class WeakMediaHandler: NSObject, WKScriptMessageHandler {
    weak var target: BrowserTab?
    init(_ target: BrowserTab) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.receive(message.body) }
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    let isPrivate: Bool
    @Published var title = "新标签页"
    @Published var address = ""
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var candidates: [MediaCandidate] = []
    @Published var error: String?
    @Published var isLoading = false
    var onNewTab: ((URL) -> Void)?
    var onVisit: ((String, URL) -> Void)?
    private var observations: [NSKeyValueObservation] = []

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = _isDebugAssertConfiguration()
        configuration.userContentController.add(WeakMediaHandler(self), name: "media")
        if let file = Bundle.main.url(forResource: "MediaSniffer", withExtension: "js"), let script = try? String(contentsOf: file) {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.progress = view.estimatedProgress } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.isLoading = view.isLoading } }
        ]
    }

    static func navigationURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { return url }
        if !trimmed.contains(" "), trimmed.contains("."), let url = URL(string: "https://" + trimmed), url.host != nil { return url }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return trimmed.isEmpty ? nil : search.url
    }

    func load(_ text: String) {
        guard let url = Self.navigationURL(text) else { return }
        load(url)
    }
    func load(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { error = "仅支持 HTTP / HTTPS 网页"; return }
        error = nil
        webView.load(URLRequest(url: url))
    }
    func scan() { webView.evaluateJavaScript("window.__ptScan && window.__ptScan()", completionHandler: nil) }
    func setDesktop(_ value: Bool) { webView.customUserAgent = value ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15" : nil; webView.reload() }
    func find(_ text: String) { let config = WKFindConfiguration(); config.wraps = true; webView.find(text, configuration: config) { _ in } }

    func receive(_ body: Any) {
        guard let batch = body as? [[String: Any]] else { return }
        for record in batch.prefix(200) {
            guard let raw = record["url"] as? String, raw.count < 16000, let url = URL(string: raw), ["http", "https"].contains(url.scheme),
                  let kind = (record["kind"] as? String).flatMap(MediaKind.init(rawValue:)) ?? MediaKind.detect(url, mime: record["mime"] as? String) else { continue }
            let item = MediaCandidate(url: url, kind: kind, source: record["source"] as? String ?? "网页", page: (record["page"] as? String).flatMap(URL.init(string:)) ?? webView.url,
                                      width: record["width"] as? Int ?? 0, height: record["height"] as? Int ?? 0, mime: record["mime"] as? String, mediaTitle: MediaNaming.title(record["title"] as? String), pageTitle: MediaNaming.title(record["pageTitle"] as? String), titlePriority: min(100, max(0, record["titlePriority"] as? Int ?? 0)))
            merge(item)
        }
    }

    private func merge(_ item: MediaCandidate) {
        if let index = candidates.firstIndex(where: { $0.id == item.id }) {
            var updated = item
            let previous = candidates[index]
            if previous.mediaTitle != nil && (updated.mediaTitle == nil || previous.titlePriority > updated.titlePriority) {
                updated.mediaTitle = previous.mediaTitle; updated.titlePriority = previous.titlePriority
            }
            updated.pageTitle = updated.pageTitle ?? previous.pageTitle
            updated.width = max(updated.width, previous.width); updated.height = max(updated.height, previous.height)
            if updated.mime?.isEmpty != false { updated.mime = previous.mime }
            candidates[index] = updated
        } else if candidates.count < 2000 { candidates.append(item) }
    }

    private func addResponse(_ response: URLResponse) {
        guard let url = response.url, let kind = MediaKind.detect(url, mime: response.mimeType) else { return }
        let candidate = MediaCandidate(url: url, kind: kind, source: "导航响应", page: webView.url, mime: response.mimeType, pageTitle: MediaNaming.title(webView.title))
        merge(candidate)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { error = nil }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { candidates = []; address = webView.url?.absoluteString ?? "" }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        title = webView.title ?? webView.url?.host ?? "网页"
        address = webView.url?.absoluteString ?? ""
        if let url = webView.url, !isPrivate { onVisit?(title, url) }
        scan()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
    private func show(_ error: Error) { if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "网页进程已结束，请重新加载" }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        addResponse(navigationResponse.response)
        if !navigationResponse.canShowMIMEType { error = "已将可识别的媒体加入嗅探列表，请从列表下载"; decisionHandler(.cancel) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload {
            if let kind = MediaKind.detect(url) { candidates.append(MediaCandidate(url: url, kind: kind, source: "下载链接", page: webView.url, pageTitle: MediaNaming.title(webView.title))) }
            error = "请在嗅探列表确认下载，或粘贴资源地址到下载页"
            decisionHandler(.cancel); return
        }
        guard ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else { decisionHandler(.cancel); error = "已阻止外部应用跳转"; return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { onNewTab?(url) }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host ?? "网页提示", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, fallback: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host ?? "网页确认", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert) { completionHandler(false) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host ?? "网页输入", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        present(alert) { completionHandler(nil) }
    }
    private func present(_ alert: UIAlertController, fallback: @escaping () -> Void) {
        guard let controller = webView.window?.rootViewController else { fallback(); return }
        var top = controller
        while let presented = top.presentedViewController { top = presented }
        guard !top.isBeingDismissed, !(top is UIAlertController) else { fallback(); return }
        top.present(alert, animated: true)
    }
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selected: UUID?
    @Published var bookmarks: [WebLink] = []
    @Published var history: [WebLink] = []
    var current: BrowserTab? { tabs.first { $0.id == selected } }
    init() {
        bookmarks = Self.read("bookmarks"); history = Self.read("history")
        newTab()
    }
    private static func read(_ key: String) -> [WebLink] { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([WebLink].self, from: $0) } ?? [] }
    private func save(_ key: String, _ value: [WebLink]) { if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) } }
    func newTab(url: URL? = nil, isPrivate: Bool = true) {
        guard tabs.count < 30 else { return }
        let tab = BrowserTab(isPrivate: isPrivate)
        tab.onNewTab = { [weak self, weak tab] url in self?.newTab(url: url, isPrivate: tab?.isPrivate ?? true) }
        tab.onVisit = { [weak self] title, url in
            guard let self else { return }
            self.history.removeAll { $0.url == url }
            self.history.insert(WebLink(title: title, url: url), at: 0)
            self.history = Array(self.history.prefix(300)); self.save("history", self.history)
        }
        tabs.append(tab); selected = tab.id
        if let url { tab.load(url) }
    }
    func close(_ tab: BrowserTab) {
        tab.webView.stopLoading(); tabs.removeAll { $0.id == tab.id }
        if selected == tab.id { selected = tabs.last?.id }
        if tabs.isEmpty { newTab() }
    }
    func bookmark(_ tab: BrowserTab) {
        guard let url = tab.webView.url else { return }
        if bookmarks.contains(where: { $0.url == url }) { bookmarks.removeAll { $0.url == url } }
        else { bookmarks.insert(WebLink(title: tab.title, url: url), at: 0) }
        save("bookmarks", bookmarks)
    }
    func removeBookmark(_ id: UUID) { bookmarks.removeAll { $0.id == id }; save("bookmarks", bookmarks) }
    func clearHistory() { history = []; save("history", []) }
    func clearWebData() async {
        for tab in tabs { tab.webView.stopLoading() }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
        tabs = []; selected = nil; clearHistory(); newTab()
    }
}

struct WebSurface: UIViewRepresentable {
    let tab: BrowserTab
    func makeUIView(context: Context) -> WKWebView { tab.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
