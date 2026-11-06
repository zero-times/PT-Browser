import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var scope = 0
    @State private var query = ""
    @State private var folder = ""
    @State private var favoritesOnly = false
    @State private var newestFirst = true
    @State private var listMode = false
    @State private var hiddenType = LibraryMediaFilter.all
    @State private var dateGrouped = false
    @State private var importing = false
    @State private var pickingFolder = false
    @State private var vaultSheet = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var selectionMode = false
    @State private var selected = Set<String>()
    @State private var viewer: ViewerSelection?
    @StateObject private var viewerPlayback = PlaybackModel()
    @State private var editing: MediaItem?
    @State private var editedName = ""
    @State private var moving: [MediaItem] = []
    @State private var deleting: [MediaItem] = []
    @State private var shareURLs: [URL] = []
    @State private var sharing = false
    @State private var detail: String?
    private var filtered: [MediaItem] {
        library.snapshot.items.filter { item in
            let category = scope == 3 ? item.isEncrypted && hiddenType.includes(item) : !item.isEncrypted && (scope == 0 || scope == 1 && item.kind == .image || scope == 2 && item.kind != .image)
            return category && (!favoritesOnly || item.favorite) && (folder.isEmpty || item.folder == folder) && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query))
        }.sorted { newestFirst ? $0.created > $1.created : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var dateSections: [LibraryDateGroup] { LibraryDateGroup.sections(filtered) }
    private var displayItems: [MediaItem] { dateGrouped ? dateSections.flatMap(\.items) : filtered }
    private var hasFilters: Bool { !query.isEmpty || favoritesOnly || !folder.isEmpty || (scope == 3 && hiddenType != .all) }
    private var selectedItems: [MediaItem] { filtered.filter { selected.contains($0.id) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    storageCard
                    Picker("媒体分类", selection: $scope) {
                        Text("全部").tag(0); Text("图片").tag(1); Text("影音").tag(2); Text("隐藏").tag(3)
                    }.pickerStyle(.segmented)
                    if scope == 3 && library.snapshot.unlocked {
                        Picker("隐藏媒体类型", selection: $hiddenType) {
                            ForEach(LibraryMediaFilter.allCases) { type in Text(type.title).tag(type) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("hiddenMediaType")
                    }
                    HStack {
                        Menu {
                            Button("全部文件夹") { folder = "" }
                            ForEach(library.snapshot.folders, id: \.self) { path in Button(path) { folder = path } }
                        } label: { Label(folder.isEmpty ? "全部文件夹" : folder, systemImage: "folder").lineLimit(1) }
                        Spacer()
                        Text("\(filtered.count) 项").font(.caption).foregroundStyle(.secondary)
                        Menu {
                            Toggle("仅看收藏", isOn: $favoritesOnly)
                            Toggle("按最新排序", isOn: $newestFirst)
                            Toggle("列表视图", isOn: $listMode)
                            Toggle("按日期分组", isOn: $dateGrouped).accessibilityIdentifier("groupMediaByDate")
                        } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }.accessibilityLabel("筛选与排序")
                    }.font(.subheadline)
                    if scope == 3 && !library.snapshot.unlocked { lockedState }
                    else if filtered.isEmpty { emptyState }
                    else { mediaContent }
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("媒体库")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索媒体名称")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if library.snapshot.unlocked { Button { library.lock(); scope = 0 } label: { Image(systemName: "lock.open").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("锁定加密库") }
                    else { Image(systemName: "shield.lefthalf.filled").foregroundStyle(.teal).accessibilityLabel("本地私密媒体库") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(selectionMode ? "完成" : "选择") { selectionMode.toggle(); selected.removeAll() }.disabled(filtered.isEmpty && !selectionMode)
                    Menu {
                        Button { importing = true } label: { Label("从 Files 导入媒体", systemImage: "square.and.arrow.down") }
                        Button { newFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                        Button { pickingFolder = true } label: { Label("连接其他文件库", systemImage: "externaldrive.badge.plus") }
                        Button { Task { await library.refresh() } } label: { Label("重新扫描文件夹", systemImage: "arrow.clockwise") }
                    } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("添加媒体")
                }
            }
            .safeAreaInset(edge: .bottom) { if selectionMode { selectionBar } }
            .overlay(alignment: .top) { if library.busy { ProgressView("正在处理文件…").font(.caption).padding(12).background(.regularMaterial, in: Capsule()).padding() } }
            .refreshable { await library.refresh() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie, .audio], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): Task { await library.importFiles(urls, folder: folder) }; case .failure(let error): library.error = error.localizedDescription }
            }
            .sheet(isPresented: $pickingFolder) { FolderPicker { url in Task { await library.selectFolder(url); folder = "" } } }
            .sheet(isPresented: $vaultSheet) { VaultSheet() }
            .fullScreenCover(item: $viewer, onDismiss: { viewerPlayback.stop() }) { selection in MediaViewer(items: selection.items, startingID: selection.id, playback: viewerPlayback).environmentObject(library) }
            .sheet(isPresented: $sharing) { ShareSheet(urls: shareURLs) }
            .sheet(isPresented: Binding(get: { !moving.isEmpty }, set: { if !$0 { moving = [] } })) { moveSheet }
            .alert("新建文件夹", isPresented: $newFolder) {
                TextField("文件夹名称", text: $folderName)
                Button("取消", role: .cancel) { folderName = "" }
                Button("创建") { let name = folderName; folderName = ""; Task { await library.perform { try await $0.createFolder(name, parent: folder) } } }
            }
            .alert("重命名", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("文件名", text: $editedName)
                Button("取消", role: .cancel) { editing = nil }
                Button("保存") { if let item = editing { let name = editedName; Task { await library.perform { try await $0.rename(item, name: name) } } }; editing = nil }
            }
            .confirmationDialog("永久删除 \(deleting.count) 项媒体？", isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), titleVisibility: .visible) {
                Button("永久删除", role: .destructive) { let items = deleting; deleting = []; Task { await mutate(items) { repo, item in try await repo.delete(item) } } }
                Button("取消", role: .cancel) { deleting = [] }
            } message: { Text("文件将从所选 Files 文件夹中删除，此操作无法撤销。") }
            .alert("文件校验", isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) { Button("好") { detail = nil } } message: { Text(detail ?? "") }
            .onChange(of: scope) { _, _ in selected.removeAll(); folder = "" }
            .onChange(of: hiddenType) { _, _ in selected.removeAll() }
            .onChange(of: query) { _, _ in selected.formIntersection(Set(filtered.map(\.id))) }
            .onChange(of: folder) { _, _ in selected.removeAll() }
            .onChange(of: favoritesOnly) { _, _ in selected.formIntersection(Set(filtered.map(\.id))) }
            .onChange(of: library.generation) { _, _ in viewerPlayback.stop(); viewer = nil; selected.removeAll(); shareURLs = []; sharing = false; detail = nil; editing = nil; moving = []; deleting = [] }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR PRIVATE COLLECTION").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.teal)
            Text("好好收藏，自在浏览。").font(.title2.bold())
            Text("图片、视频与喜欢的每一刻，都在自己的文件夹里。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 12)
    }
    private var storageCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "externaldrive.fill").font(.title).foregroundStyle(.teal).frame(width: 56, height: 56).background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text(library.root.lastPathComponent).font(.headline).lineLimit(1)
                Text("Files 文件库 · \(ByteCountFormatter.string(fromByteCount: library.publicItems.reduce(0) { $0 + $1.bytes }, countStyle: .file)) 公开媒体")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { pickingFolder = true } label: { Image(systemName: "arrow.up.right").frame(width: 44, height: 44) }.accessibilityLabel("连接 Files 文件夹")
        }.padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
    private var lockedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 48, weight: .light)).foregroundStyle(.teal).padding(20).background(.teal.opacity(0.08), in: Circle())
            Text(library.snapshot.hasVault ? "隐藏的收藏，只为你打开" : "给私密收藏一个安全的家").font(.headline)
            Text(library.snapshot.hasVault ? "输入这个文件夹的加密密码，恢复你的隐藏媒体。" : "密码保护文件与名称。更换包名后，连接原文件夹仍可解密。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(library.snapshot.hasVault ? "解锁加密库" : "创建加密库") { vaultSheet = true }.buttonStyle(.borderedProminent).controlSize(.large)
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }
    private var emptyState: some View {
        ContentUnavailableView {
            Label(hasFilters ? "没有匹配的媒体" : "收藏从这里开始", systemImage: hasFilters ? "magnifyingglass" : "photo.stack")
        } description: {
            Text(hasFilters ? "试试切换媒体类型、文件夹或取消筛选。" : scope == 3 ? "在普通库长按媒体，选择「加密并隐藏」。" : "从 Files 导入，或到浏览器发现网页中的图片与视频。")
        } actions: {
            if hasFilters {
                Button("清除筛选") { query = ""; folder = ""; favoritesOnly = false; hiddenType = .all; selected.removeAll() }.buttonStyle(.bordered)
            } else if scope != 3 { Button("从 Files 导入") { importing = true }.buttonStyle(.bordered) }
        }.padding(.vertical, 16)
    }
    @ViewBuilder private var mediaContent: some View {
        if dateGrouped {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(dateSections) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(group.day, format: .dateTime.year().month().day()).font(.headline)
                                .accessibilityIdentifier("mediaDateHeading")
                            Spacer()
                            Text("\(group.items.count) 项").font(.caption).foregroundStyle(.secondary)
                        }
                        if listMode { mediaList(group.items) } else { mediaGrid(group.items) }
                    }
                }
            }
        } else if listMode { mediaList(filtered) }
        else { mediaGrid(filtered) }
    }
    private func mediaGrid(_ items: [MediaItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 14) {
            ForEach(items) { item in
                Button { activate(item) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MediaThumbnail(item: item).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .topTrailing) { if selectionMode { selectionMark(item).padding(8) } }
                        Text(item.name).font(.caption).lineLimit(1).foregroundStyle(.primary)
                        Text(item.byteLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).contentShape(Rectangle())
                    .accessibilityIdentifier("mediaItem-\(item.name)")
                    .accessibilityLabel("\(item.name)，\(item.kind.title)，\(item.byteLabel)")
                    .contextMenu { actions(item) }
            }
        }
    }
    private func mediaList(_ items: [MediaItem]) -> some View {
        LazyVStack(spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Button { activate(item) } label: {
                        HStack(spacing: 12) {
                            MediaThumbnail(item: item).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 6) { Text(item.name).lineLimit(2); Text("\(item.kind.title) · \(item.byteLabel)").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if selectionMode { selectionMark(item) }
                        }
                    }.buttonStyle(.plain).contentShape(Rectangle())
                        .accessibilityIdentifier("mediaItem-\(item.name)")
                        .accessibilityLabel("\(item.name)，\(item.kind.title)，\(item.byteLabel)")
                    if !selectionMode { Menu { actions(item) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("\(item.name)的操作") }
                }.padding(8).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private func selectionMark(_ item: MediaItem) -> some View { Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, .teal).shadow(radius: 2) }
    private func activate(_ item: MediaItem) {
        if selectionMode { if !selected.insert(item.id).inserted { selected.remove(item.id) } }
        else { viewer = ViewerSelection(items: displayItems, id: item.id) }
    }
    @ViewBuilder private func actions(_ item: MediaItem) -> some View {
        Button { activate(item) } label: { Label("打开", systemImage: item.kind.icon) }
        Button { Task { await library.perform { try await $0.favorite(item) } } } label: { Label(item.favorite ? "取消收藏" : "收藏", systemImage: item.favorite ? "heart.slash" : "heart") }
        Button { editing = item; editedName = item.name } label: { Label("重命名", systemImage: "pencil") }
        if item.isEncrypted {
            Button { Task { await mutate([item]) { try await $0.restore($1) } } } label: { Label("解密到普通库", systemImage: "lock.open") }
        } else {
            Button { if library.snapshot.unlocked { Task { await mutate([item]) { try await $0.encrypt($1) } } } else { vaultSheet = true } } label: { Label("加密并隐藏", systemImage: "lock") }
            Button { moving = [item] } label: { Label("移动到文件夹", systemImage: "folder") }
            Button { Task { await share([item]) } } label: { Label("分享 / 导出", systemImage: "square.and.arrow.up") }
        }
        Button { Task { do { detail = try await library.repository.verify(item) } catch { library.error = error.localizedDescription } } } label: { Label("校验文件", systemImage: "checkmark.shield") }
        Button(role: .destructive) { deleting = [item] } label: { Label("删除", systemImage: "trash") }
    }
    private var selectionBar: some View {
        HStack {
            Button(selected.count == filtered.count ? "全不选" : "全选") { selected = selected.count == filtered.count ? [] : Set(filtered.map(\.id)) }
            Spacer()
            Text("\(selected.count) 项").font(.caption).foregroundStyle(.secondary)
            Menu {
                if scope == 3 { Button("解密到普通库") { Task { await mutate(selectedItems) { try await $0.restore($1) } } } }
                else {
                    Button("加密并隐藏") { if library.snapshot.unlocked { Task { await mutate(selectedItems) { try await $0.encrypt($1) } } } else { vaultSheet = true } }
                    Button("移动到文件夹") { moving = selectedItems }
                    Button("分享 / 导出") { Task { await share(selectedItems) } }
                }
                Button("删除", role: .destructive) { deleting = selectedItems }
            } label: { Label("操作", systemImage: "ellipsis.circle").frame(minHeight: 44) }.disabled(selected.isEmpty || library.busy)
        }.padding(.horizontal, 20).padding(.vertical, 8).background(.bar)
    }
    private var moveSheet: some View {
        NavigationStack {
            List {
                Button("文件库根目录") { move(to: "") }
                ForEach(library.snapshot.folders, id: \.self) { path in Button(path) { move(to: path) } }
            }.navigationTitle("移动 \(moving.count) 项至")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { moving = [] } } }
        }
    }
    private func move(to path: String) { let items = moving; moving = []; Task { await mutate(items) { try await $0.rename($1, name: $1.name, folder: path) } } }
    private func mutate(_ items: [MediaItem], action: (LibraryRepository, MediaItem) async throws -> Void) async {
        await library.perform { repo in
            for item in items { try await action(repo, item) }
        }
        selected.removeAll()
    }
    private func share(_ items: [MediaItem]) async {
        do { var urls: [URL] = []; for item in items { urls.append(try await library.repository.playableURL(item)) }; shareURLs = urls; sharing = !urls.isEmpty }
        catch { library.error = error.localizedDescription }
    }
}

struct ViewerSelection: Identifiable { let items: [MediaItem]; let id: String }

struct VaultSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var submitting = false
    @State private var localError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.teal)
                        Text(library.snapshot.hasVault ? "打开这份私密收藏" : "创建文件夹加密密码").font(.title2.bold())
                        Text("密码属于当前文件夹。换包名、换设备后，仍可通过原文件夹和密码解密。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                Section("加密密码") {
                    SecureField(library.snapshot.hasVault ? "输入原密码" : "至少 8 个字符", text: $password).textContentType(library.snapshot.hasVault ? .password : .newPassword).accessibilityIdentifier("vaultPassword")
                    if !library.snapshot.hasVault { SecureField("再次输入密码", text: $confirmation).textContentType(.newPassword).accessibilityIdentifier("vaultConfirmation") }
                }
                if let localError { Section { Text(localError).foregroundStyle(.red) } }
                Section {
                    Button { submit() } label: { HStack { Spacer(); if submitting { ProgressView() }; Text(library.snapshot.hasVault ? "解锁" : "创建并解锁"); Spacer() } }
                        .disabled(submitting || password.isEmpty || (!library.snapshot.hasVault && (password.count < 8 || password != confirmation)))
                        .accessibilityIdentifier("vaultSubmit")
                } footer: { Text("密码无法找回。请备份整个文件夹（包括 .ptbrowser 隐藏目录）。锁定时不会显示隐藏媒体的名称或缩略图。") }
            }.navigationTitle(library.snapshot.hasVault ? "解锁加密库" : "创建加密库").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(submitting) } }
                .onDisappear { password = ""; confirmation = "" }
        }
    }
    private func submit() {
        let value = password
        submitting = true; localError = nil
        Task {
            let create = !library.snapshot.hasVault
            await library.perform { repo in if create { try await repo.createVault(password: value) } else { try await repo.unlock(password: value) } }
            submitting = false
            if library.snapshot.unlocked { password = ""; confirmation = ""; dismiss() }
            else { localError = library.error ?? "解锁失败"; library.error = nil }
        }
    }
}
