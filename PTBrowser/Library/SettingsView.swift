import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var browser: BrowserModel
    @State private var pickingFolder = false
    @State private var vaultSheet = false
    @State private var clearWeb = false
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "safari.fill").font(.system(size: 40)).foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 4) { Text("PT Browser").font(.title2.bold()); Text("浏览 · 收藏 · 私密保存").font(.subheadline).foregroundStyle(.secondary) }
                    }.padding(.vertical, 12)
                }
                Section {
                    LabeledContent("当前文件夹", value: library.root.lastPathComponent)
                    Text(library.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button { pickingFolder = true } label: { Label("选择 / 恢复已有文件夹", systemImage: "externaldrive.badge.plus") }
                    Button { Task { await library.refresh() } } label: { Label("重新扫描文件夹", systemImage: "arrow.clockwise") }
                } header: { Text("Files 文件库") } footer: { Text("换包名后，重新选择旧文件夹即可读取普通媒体；使用原密码解锁隐藏媒体。为在卸载后保留文件，请选择 iCloud Drive 或独立文件提供商中的文件夹。『在我的 iPhone / PT Browser』随 App 卸载删除。") }
                Section {
                    LabeledContent("加密库", value: library.snapshot.unlocked ? "已解锁" : library.snapshot.hasVault ? "已锁定" : "尚未创建")
                    if library.snapshot.unlocked { Button { library.lock() } label: { Label("立即锁定", systemImage: "lock") } }
                    else { Button { vaultSheet = true } label: { Label(library.snapshot.hasVault ? "解锁加密库" : "创建加密库", systemImage: "lock.shield") } }
                    LabeledContent("离开 App", value: "自动锁定并清理解密缓存")
                    LabeledContent("文件加密", value: "AES-256-GCM")
                    LabeledContent("密码派生", value: "PBKDF2-SHA256 · 310,000 次")
                } header: { Text("隐私与加密") } footer: { Text("加密密码不上传、不写入钥匙串，无法找回。备份时必须复制整个文件夹，包括 .ptbrowser 隐藏目录；只复制普通图片/视频不会包含隐藏媒体。系统截图与录屏无法被完全阻止。") }
                Section {
                    LabeledContent("新标签页默认", value: "无痕")
                    Button { clearWeb = true } label: { Label("清除网站数据与浏览历史", systemImage: "trash") }
                } header: { Text("浏览器") } footer: { Text("无痕标签页使用独立临时网站数据。普通标签页保留登录 Cookie；清除网站数据会退出网站登录并关闭标签页。书签会保留。下载记录单独在下载页管理。") }
                Section("显示") {
                    Picker("外观", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                }
                Section("关于") {
                    LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    LabeledContent("包名", value: Bundle.main.bundleIdentifier ?? "com.hoai.ptbrowser")
                    Text("支持 iOS 可解码的图片、音视频与非 DRM HLS 点播离线包。嗅探列表会把可直接保存的源视频排在前面；加密视频会提示密钥可能过期。网页嗅探覆盖 DOM、动态元素、srcset、Fetch、XHR 与资源性能记录。Blob、DRM、专有分片协议和防盗链资源可能无法下载。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("设置")
                .sheet(isPresented: $pickingFolder) { FolderPicker { url in Task { await library.selectFolder(url) } } }
                .sheet(isPresented: $vaultSheet) { VaultSheet() }
                .confirmationDialog("清除网站数据并关闭全部标签页？", isPresented: $clearWeb, titleVisibility: .visible) { Button("清除", role: .destructive) { Task { await browser.clearWebData() } }; Button("取消", role: .cancel) {} }
        }
    }
}
