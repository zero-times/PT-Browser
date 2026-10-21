import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var adding = false
    @State private var url = ""
    @State private var expectedHash = ""
    @State private var kind = MediaKind.video
    @State private var detail: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("每一份收藏，都有迹可循。").font(.title2.bold())
                        Text("下载、校验、保存到 Files。\n完成后前往媒体库浏览或加密隐藏。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                if downloads.jobs.isEmpty { ContentUnavailableView("下载队列是空的", systemImage: "arrow.down.to.line", description: Text("从浏览器嗅探媒体，或添加一个直接下载地址。")) }
                ForEach(downloads.jobs) { job in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Image(systemName: job.state == .completed ? "checkmark.seal" : job.kind.icon).font(.title2).foregroundStyle(job.state == .failed ? .orange : .teal).frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 4) { Text(job.name).font(.subheadline.weight(.medium)).lineLimit(2); Text("\(job.url.host ?? "") · \(job.destinationName)").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Menu {
                                if [.paused, .failed].contains(job.state) { Button("继续 / 重试") { downloads.resume(job.id) } }
                                if job.state == .running { Button("暂停") { downloads.pause(job.id) } }
                                if [.preparing, .running, .paused].contains(job.state) { Button("取消", role: .destructive) { downloads.cancel(job.id) } }
                                Button("复制下载地址") { UIPasteboard.general.url = job.url }
                                if let hash = job.sha256 { Button("查看 SHA-256") { detail = hash } }
                                if ![.running, .preparing, .verifying].contains(job.state) { Button("移除记录", role: .destructive) { downloads.remove(job.id) } }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("\(job.name)下载操作")
                        }
                        if [.preparing, .running, .paused, .verifying].contains(job.state) { if job.state == .verifying || job.state == .preparing { ProgressView() } else { ProgressView(value: job.progress) } }
                        HStack {
                            Text(stateText(job)).font(.caption).foregroundStyle(job.state == .failed ? .orange : .secondary)
                            Spacer()
                            if job.state == .running { Text(job.isHLS ? "\(Int(job.progress * 100))%" : "\(ByteCountFormatter.string(fromByteCount: job.received, countStyle: .file)) / \(job.expected > 0 ? ByteCountFormatter.string(fromByteCount: job.expected, countStyle: .file) : "未知大小")").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        if let message = job.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(.vertical, 8)
                }
            }.navigationTitle("下载")
                .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加下载") } }
                .sheet(isPresented: $adding) { addSheet }
                .alert("SHA-256", isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) { Button("复制") { UIPasteboard.general.string = detail; detail = nil }; Button("好", role: .cancel) { detail = nil } } message: { Text(detail ?? "") }
        }
    }
    private func stateText(_ job: DownloadJob) -> String {
        switch job.state { case .preparing: "准备中"; case .running: "下载中"; case .paused: "已暂停"; case .verifying: "校验并保存中"; case .completed: "已完成"; case .failed: "失败，可重试"; case .cancelled: "已取消" }
    }
    private var addSheet: some View {
        NavigationStack {
            Form {
                Section("直接媒体地址") { TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled(); Picker("媒体类型", selection: $kind) { ForEach(MediaKind.allCases, id: \.self) { Text($0.title).tag($0) } } }
                Section { TextField("预期 SHA-256，64 位十六进制", text: $expectedHash).textInputAutocapitalization(.never).autocorrectionDisabled() } header: { Text("完整性校验（可选）") } footer: { Text("直接地址下载不带网页登录信息。需要登录的网站请从浏览器嗅探列表下载。HLS 仅支持系统可离线保存的非 DRM 点播资源，HLS 不使用单文件哈希。") }
            }.navigationTitle("添加下载").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("下载") {
                        guard let resource = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(resource.scheme?.lowercased() ?? ""), resource.host != nil else { downloads.error = "请输入完整的 HTTP / HTTPS 地址"; return }
                        let hash = expectedHash.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard hash.isEmpty || hash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { downloads.error = "SHA-256 必须是 64 位十六进制字符"; return }
                        let candidate = MediaCandidate(url: resource, kind: MediaKind.detect(resource) ?? kind, source: "手动添加")
                        Task { await downloads.enqueue(candidate, tab: nil, expectedSHA256: hash) }
                        adding = false; url = ""; expectedHash = ""
                    }.disabled(url.isEmpty) }
                }
        }
    }
}
