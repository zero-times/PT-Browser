import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var browser: BrowserModel
    var body: some View {
        Group { if let tab = browser.current { BrowserTabView(tab: tab) } }
    }
}

private struct BrowserTabView: View {
    @EnvironmentObject private var browser: BrowserModel
    @EnvironmentObject private var downloads: DownloadCenter
    @ObservedObject var tab: BrowserTab
    @State private var input = ""
    @State private var sniffing = false
    @State private var tabsSheet = false
    @State private var linksSheet = false
    @State private var historyMode = false
    @State private var desktop = false
    @State private var findSheet = false
    @State private var findText = ""
    @State private var share = false
    @FocusState private var addressFocused: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: tab.isPrivate ? "hand.raised.fill" : "globe").foregroundStyle(tab.isPrivate ? .teal : .secondary).font(.caption)
                    TextField("搜索或输入网址", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch).submitLabel(.go)
                        .focused($addressFocused).onSubmit { tab.load(input); addressFocused = false }.accessibilityIdentifier("browserAddress")
                    Button { if tab.isLoading { tab.webView.stopLoading() } else if tab.webView.url != nil { tab.webView.reload() } else { tab.load(input) } } label: { Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel(tab.isLoading ? "停止加载" : "刷新网页")
                }.padding(.leading, 16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16).padding(.vertical, 8)
                if tab.isLoading { ProgressView(value: tab.progress).tint(.teal).accessibilityLabel("网页加载进度") }
                if let error = tab.error {
                    HStack { Image(systemName: "exclamationmark.circle"); Text(error).font(.caption); Spacer(); Button { tab.error = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("关闭网页提示") }.padding(.leading, 16).background(.orange.opacity(0.10))
                }
                ZStack {
                    WebSurface(tab: tab).id(tab.id)
                    if tab.webView.url == nil && !tab.isLoading { startPage }
                }
                HStack {
                    Button { tab.webView.goBack() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(!tab.canGoBack).accessibilityLabel("后退")
                    Button { tab.webView.goForward() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(!tab.canGoForward).accessibilityLabel("前进")
                    Spacer()
                    Button { tab.scan(); sniffing = true } label: {
                        HStack(spacing: 6) { Image(systemName: "waveform.path.ecg"); Text("\(tab.candidates.count)").font(.subheadline.monospacedDigit()) }.padding(.horizontal, 12).frame(height: 44).background(.teal.opacity(0.12), in: Capsule())
                    }.accessibilityLabel("嗅探媒体，\(tab.candidates.count) 项")
                    Spacer()
                    Button { tabsSheet = true } label: { ZStack { Image(systemName: "square.on.square").font(.title3); Text("\(browser.tabs.count)").font(.system(size: 9, weight: .bold)).offset(y: 2) }.frame(width: 44, height: 44) }.accessibilityLabel("标签页")
                    Menu {
                        Button { browser.bookmark(tab) } label: { Label("收藏 / 取消收藏网页", systemImage: "bookmark") }
                        Button { historyMode = false; linksSheet = true } label: { Label("书签", systemImage: "book") }
                        Button { historyMode = true; linksSheet = true } label: { Label("浏览历史", systemImage: "clock") }
                        Toggle("桌面版网站", isOn: $desktop)
                        Button { findSheet = true } label: { Label("在页面中查找", systemImage: "doc.text.magnifyingglass") }
                        Button { tab.webView.pageZoom = min(tab.webView.pageZoom + 0.1, 2) } label: { Label("放大网页", systemImage: "textformat.size.larger") }
                        Button { tab.webView.pageZoom = max(tab.webView.pageZoom - 0.1, 0.5) } label: { Label("缩小网页", systemImage: "textformat.size.smaller") }
                        if tab.webView.url != nil { Button { share = true } label: { Label("分享网页", systemImage: "square.and.arrow.up") } }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("网页菜单")
                }.padding(.horizontal, 8).background(.bar)
            }
            .background(Color(.systemGroupedBackground)).toolbar(.hidden, for: .navigationBar)
            .onAppear { input = tab.address }
            .onChange(of: tab.address) { _, address in if !addressFocused { input = address } }
            .onChange(of: tab.id) { _, _ in input = tab.address }
            .onChange(of: desktop) { _, value in tab.setDesktop(value) }
            .sheet(isPresented: $sniffing) { SnifferSheet(tab: tab) }
            .sheet(isPresented: $tabsSheet) { tabList }
            .sheet(isPresented: $linksSheet) { linkList }
            .sheet(isPresented: $share) { if let url = tab.webView.url { ShareSheet(urls: [url]) } }
            .alert("在页面中查找", isPresented: $findSheet) { TextField("关键字", text: $findText); Button("取消", role: .cancel) {}; Button("查找下一个") { tab.find(findText) } }
        }
    }
    private var startPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "safari").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.teal).padding(.top, 48)
                VStack(alignment: .leading, spacing: 8) {
                    Text("从好奇，开始收藏。").font(.largeTitle.bold())
                    Text("自在浏览网页，发现图片与视频。\n点亮下方的波形按钮，查看可下载的媒体。")
                        .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                }
                Label(tab.isPrivate ? "无痕标签页 · 不记录浏览历史" : "普通标签页 · 保留登录与历史", systemImage: tab.isPrivate ? "hand.raised" : "clock").font(.caption).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                if !browser.bookmarks.isEmpty {
                    Text("常去的地方").font(.headline)
                    ForEach(browser.bookmarks.prefix(6)) { link in Button { tab.load(link.url) } label: { HStack { Image(systemName: "bookmark"); Text(link.title).lineLimit(1); Spacer(); Image(systemName: "arrow.up.right") }.padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)) } }
                }
                Text("仅下载你有权保存的媒体。受 DRM 保护、内存 Blob 与部分网站专有的分段资源可能无法下载。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 16)
            }.padding(24).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color(.systemGroupedBackground))
    }
    private var tabList: some View {
        NavigationStack {
            List {
                ForEach(browser.tabs) { item in
                    HStack {
                        Button { browser.selected = item.id; tabsSheet = false } label: { HStack { Image(systemName: item.isPrivate ? "hand.raised" : "globe"); VStack(alignment: .leading) { Text(item.title).lineLimit(1); Text(item.address.isEmpty ? "新标签页" : item.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if item.id == browser.selected { Image(systemName: "checkmark") } } }
                        Button(role: .destructive) { browser.close(item) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("关闭\(item.title)")
                    }
                }
            }.navigationTitle("标签页")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { tabsSheet = false } }
                    ToolbarItem(placement: .primaryAction) { Menu { Button("新无痕标签页") { browser.newTab(); tabsSheet = false }; Button("新普通标签页") { browser.newTab(isPrivate: false); tabsSheet = false } } label: { Image(systemName: "plus") }.accessibilityLabel("新建标签页") }
                }
        }
    }
    private var linkList: some View {
        NavigationStack {
            List {
                if (historyMode ? browser.history : browser.bookmarks).isEmpty { ContentUnavailableView(historyMode ? "暂无浏览历史" : "暂无书签", systemImage: historyMode ? "clock" : "bookmark") }
                ForEach(historyMode ? browser.history : browser.bookmarks) { item in
                    Button { tab.load(item.url); linksSheet = false } label: { VStack(alignment: .leading, spacing: 4) { Text(item.title).foregroundStyle(.primary); Text(item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                        .swipeActions { if !historyMode { Button("删除", role: .destructive) { browser.removeBookmark(item.id) } } }
                }
            }.navigationTitle(historyMode ? "浏览历史" : "书签")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { linksSheet = false } }; ToolbarItem(placement: .primaryAction) { if historyMode { Button("清空") { browser.clearHistory() } } } }
        }
    }
}

struct SnifferSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var downloads: DownloadCenter
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "all"
    @State private var selected = Set<String>()
    @State private var queued = Set<String>()
    @State private var minWidth = false
    private var items: [MediaCandidate] { tab.candidates.filter { (kind == "all" || $0.kind.rawValue == kind) && (!minWidth || $0.kind != .image || $0.width >= 300 || $0.width == 0) } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("类型", selection: $kind) { Text("全部").tag("all"); Text("图片").tag("image"); Text("视频").tag("video"); Text("音频").tag("audio") }.pickerStyle(.segmented)
                    Toggle("过滤宽度小于 300px 的已知小图", isOn: $minWidth).font(.caption)
                    Text("发现 \(items.count) 项 · 下载会携带当前网页的登录 Cookie 与来源信息。先保存为普通媒体，之后可在媒体库加密。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if items.isEmpty { ContentUnavailableView("暂未发现媒体", systemImage: "waveform.path.ecg", description: Text("播放视频、滚动网页，或重新扫描。内存 Blob、DRM 和网站自有协议不一定可下载。")) }
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Button { if !selected.insert(item.id).inserted { selected.remove(item.id) } } label: { Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("选择\(item.name)")
                        VStack(alignment: .leading, spacing: 6) {
                            Label(item.name, systemImage: item.kind.icon).font(.subheadline).lineLimit(2)
                            Text("\(item.isHLS ? "HLS 离线包" : item.kind.title) · \(item.width > 0 ? "\(item.width) × \(item.height) · " : "")\(item.source)").font(.caption).foregroundStyle(.secondary)
                            Text(item.url.host ?? "").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { queue(item) } label: { Image(systemName: queued.contains(item.id) ? "checkmark" : "arrow.down.circle").font(.title2).frame(width: 44, height: 44) }.buttonStyle(.borderless).disabled(queued.contains(item.id)).accessibilityLabel("下载\(item.name)")
                    }.contextMenu { Button("复制资源地址") { UIPasteboard.general.url = item.url } }
                }
            }
            .navigationTitle("网页媒体").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }; ToolbarItem(placement: .primaryAction) { Button { tab.scan() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("重新扫描") } }
            .safeAreaInset(edge: .bottom) {
                HStack { Button(selected.count == items.count ? "全不选" : "全选") { selected = selected.count == items.count ? [] : Set(items.map(\.id)) }; Spacer(); Button("下载所选 (\(selected.count))") { for item in items where selected.contains(item.id) { queue(item) }; selected.removeAll() }.buttonStyle(.borderedProminent).disabled(selected.isEmpty) }.padding().background(.bar)
            }
        }
    }
    private func queue(_ item: MediaCandidate) { queued.insert(item.id); Task { await downloads.enqueue(item, tab: tab) } }
}
