import SwiftUI

@main
struct PTBrowserApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore()
    @StateObject private var browser = BrowserModel()
    @StateObject private var downloads = DownloadCenter()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @State private var selectedTab = 0
    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView(selection: $selectedTab) {
                    LibraryView().tabItem { Label("媒体库", systemImage: "square.grid.2x2") }.tag(0)
                    BrowserView().tabItem { Label("浏览器", systemImage: "safari") }.tag(1)
                    DownloadsView().tabItem { Label("下载", systemImage: "arrow.down.circle") }.badge(downloads.jobs.filter { [.running, .preparing, .verifying].contains($0.state) }.count).tag(2)
                    SettingsView().tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(3)
                }
                .environmentObject(library).environmentObject(browser).environmentObject(downloads).tint(.teal)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                if library.privacyCovered {
                    ZStack { Color(.systemBackground).ignoresSafeArea(); VStack(spacing: 16) { Image(systemName: "lock.shield").font(.system(size: 56, weight: .light)).foregroundStyle(.teal); Text("PT Browser").font(.title2.weight(.medium)); Text("你的收藏，安心保存。").font(.subheadline).foregroundStyle(.secondary) } }.zIndex(100)
                }
            }
            .task { downloads.library = library; await library.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { library.privacyCovered = false; Task { await library.refresh() } }
                else { library.secureSessionBecameInactive() }
            }
            .alert("无法完成操作", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("好", role: .cancel) { library.error = nil } } message: { Text(library.error ?? "") }
            .alert("下载提示", isPresented: Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })) { Button("好", role: .cancel) { downloads.error = nil } } message: { Text(downloads.error ?? "") }
            .alert("文件库", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) { Button("好", role: .cancel) { library.notice = nil } } message: { Text(library.notice ?? "") }
            .onOpenURL { url in
                if url.isFileURL { selectedTab = 0; Task { await library.importFiles([url]) } }
                else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { selectedTab = 1; browser.newTab(url: url) }
            }
        }
    }
}
