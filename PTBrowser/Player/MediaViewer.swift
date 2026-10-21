import SwiftUI
import AVKit
import ImageIO

struct MediaViewer: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let items: [MediaItem]
    let startingID: String
    @State private var currentID: String?
    @State private var vertical = false
    @State private var longImage = false
    @State private var slideshow = false
    @State private var slideshowSeconds = 4.0
    @State private var autoNext = true
    @State private var shortVideos = false
    @State private var rate: Float = 1
    @State private var muted = false
    @State private var showInfo = false
    private var visibleItems: [MediaItem] { shortVideos ? items.filter { $0.kind == .video } : items }
    private var current: MediaItem? { visibleItems.first { $0.id == currentID } }
    private var index: Int { visibleItems.firstIndex { $0.id == currentID } ?? 0 }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("关闭浏览")
                Spacer()
                VStack(spacing: 2) {
                    Text(current?.name ?? "媒体浏览").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(visibleItems.isEmpty ? 0 : index + 1) / \(visibleItems.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Toggle("上下滑动切换", isOn: $vertical)
                    Toggle("长图纵向阅读", isOn: $longImage).disabled(current?.kind != .image)
                    Toggle("短视频模式", isOn: $shortVideos)
                    Toggle("自动播放下一项", isOn: $autoNext)
                    Toggle("静音", isOn: $muted)
                    Picker("播放速度", selection: $rate) { Text("0.5×").tag(Float(0.5)); Text("1×").tag(Float(1)); Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2)) }
                    Button { showInfo = true } label: { Label("媒体信息", systemImage: "info.circle") }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel("浏览设置")
            }.padding(.horizontal, 8).background(.bar)
            GeometryReader { geometry in
                if vertical {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleItems) { item in
                                page(item).frame(width: geometry.size.width, height: geometry.size.height).id(item.id)
                            }
                        }.scrollTargetLayout()
                    }.scrollTargetBehavior(.paging).scrollPosition(id: $currentID).scrollIndicators(.hidden)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(visibleItems) { item in
                                page(item).frame(width: geometry.size.width, height: geometry.size.height).id(item.id)
                            }
                        }.scrollTargetLayout()
                    }.scrollTargetBehavior(.paging).scrollPosition(id: $currentID).scrollIndicators(.hidden)
                }
            }.background(.black)
            HStack(spacing: 12) {
                Button { advance(-1) } label: { Image(systemName: "backward.end").frame(width: 44, height: 44) }.disabled(index == 0).accessibilityLabel("上一项")
                Spacer()
                if current?.kind == .image {
                    Button { slideshow.toggle() } label: { Label(slideshow ? "暂停幻灯片" : "幻灯片", systemImage: slideshow ? "pause.fill" : "play.fill") }.frame(minHeight: 44)
                    Menu { Picker("间隔", selection: $slideshowSeconds) { Text("2 秒").tag(2.0); Text("4 秒").tag(4.0); Text("8 秒").tag(8.0) } } label: { Text("\(Int(slideshowSeconds))s").font(.caption).frame(minWidth: 44, minHeight: 44) }
                } else { Text(shortVideos ? "上下滑动 · 连续播放" : "\(rate.formatted())× · \(autoNext ? "自动下一项" : "单项播放")").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { advance(1) } label: { Image(systemName: "forward.end").frame(width: 44, height: 44) }.disabled(index >= visibleItems.count - 1).accessibilityLabel("下一项")
            }.padding(.horizontal, 16).background(.bar)
        }
        .background(.black).preferredColorScheme(.dark)
        .onAppear { currentID = startingID }
        .onChange(of: shortVideos) { _, enabled in
            if enabled { vertical = true; longImage = false; slideshow = false }
            if !visibleItems.contains(where: { $0.id == currentID }) { currentID = visibleItems.first?.id }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { slideshow = false } }
        .onChange(of: currentID) { _, _ in showInfo = false }
        .task(id: "\(slideshow)-\(slideshowSeconds)-\(currentID ?? "")") {
            guard slideshow, current?.kind == .image else { return }
            try? await Task.sleep(for: .seconds(slideshowSeconds))
            guard !Task.isCancelled, slideshow else { return }
            if index < visibleItems.count - 1 { advance(1) } else { currentID = visibleItems.first?.id }
        }
        .alert("媒体信息", isPresented: $showInfo) { Button("好", role: .cancel) {} } message: { Text("\(current?.name ?? "")\n\(current?.byteLabel ?? "")\n\(current?.isEncrypted == true ? "AES-256-GCM 加密媒体" : "Files 普通媒体")\n\(current?.sha256 ?? "")") }
    }
    private func page(_ item: MediaItem) -> some View {
        MediaPage(item: item, active: item.id == currentID, longImage: longImage, rate: rate, muted: muted) {
            guard item.id == currentID else { return }
            if autoNext && index < visibleItems.count - 1 { advance(1) }
        }
    }
    private func advance(_ offset: Int) { let target = index + offset; guard visibleItems.indices.contains(target) else { return }; withAnimation { currentID = visibleItems[target].id } }
}

private struct MediaPage: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    let item: MediaItem
    let active: Bool
    let longImage: Bool
    let rate: Float
    let muted: Bool
    let ended: @MainActor @Sendable () -> Void
    @State private var url: URL?
    @State private var error: String?
    @StateObject private var playback = PlaybackModel()
    var body: some View {
        ZStack {
            Color.black
            if let error = error ?? playback.error { ContentUnavailableView("无法打开媒体", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else if let url, active {
                if item.kind == .image { ZoomableImage(url: url, longMode: longImage) }
                else { NativePlayer(player: playback.player, allowBackground: !item.isEncrypted) }
            } else if active { ProgressView("正在读取并校验…").tint(.white) }
        }
        .task(id: "\(active)-\(library.generation)") {
            guard active else { url = nil; playback.stop(); return }
            do {
                let resolved = try await library.repository.playableURL(item)
                guard !Task.isCancelled, active, (!item.isEncrypted || !library.privacyCovered) else { return }
                url = resolved
                if item.kind != .image { playback.open(resolved, item: item, rate: rate, muted: muted, ended: ended) }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onChange(of: rate) { _, value in playback.setRate(value) }
        .onChange(of: muted) { _, value in playback.player?.isMuted = value }
        .onChange(of: active) { _, value in if !value { playback.stop(); url = nil } }
        .onChange(of: scenePhase) { _, phase in if phase != .active && item.isEncrypted { playback.stop(); url = nil } }
        .onDisappear { playback.stop() }
    }
}

@MainActor
private final class PlaybackModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var error: String?
    private var endObserver: NSObjectProtocol?
    private var status: NSKeyValueObservation?
    private var periodic: Any?
    private var savedID: String?
    func open(_ url: URL, item: MediaItem, rate: Float, muted: Bool, ended: @escaping @MainActor @Sendable () -> Void) {
        stop(); error = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let current = AVPlayerItem(url: url)
        let next = AVPlayer(playerItem: current)
        player = next; savedID = item.isEncrypted ? nil : item.id
        next.isMuted = muted
        next.defaultRate = rate
        if let savedID {
            let seconds = UserDefaults.standard.double(forKey: "playback.\(savedID)")
            if seconds > 1 { next.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        }
        status = current.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { Task { @MainActor in self?.error = item.error?.localizedDescription ?? "iOS 不支持此媒体格式" } }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: current, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if let id = self?.savedID { UserDefaults.standard.removeObject(forKey: "playback.\(id)") }
                ended()
            }
        }
        periodic = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 3, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in if let id = self?.savedID, time.seconds.isFinite { UserDefaults.standard.set(time.seconds, forKey: "playback.\(id)") } }
        }
        next.playImmediately(atRate: rate)
    }
    func setRate(_ value: Float) { player?.defaultRate = value; if player?.rate != 0 { player?.rate = value } }
    func stop() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let periodic { player?.removeTimeObserver(periodic) }; periodic = nil
        status = nil; player?.replaceCurrentItem(with: nil); player = nil; savedID = nil
    }
}

private struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer?
    let allowBackground: Bool
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = allowBackground
        controller.canStartPictureInPictureAutomaticallyFromInline = allowBackground
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player; controller.allowsPictureInPicturePlayback = allowBackground }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) { controller.player = nil }
}

/// Native scrolling and pinch zoom keep tall images readable at screen width.
private struct ZoomableImage: UIViewRepresentable {
    let url: URL
    let longMode: Bool
    func makeUIView(context: Context) -> ImageScrollView { ImageScrollView() }
    func updateUIView(_ view: ImageScrollView, context: Context) { view.configure(url: url, longMode: longMode) }
    final class ImageScrollView: UIScrollView, UIScrollViewDelegate {
        private let picture = UIImageView()
        private var loadedURL: URL?
        private var longMode = false
        private var lastSize = CGSize.zero
        private var loadTask: Task<Void, Never>?
        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self; backgroundColor = .black
            minimumZoomScale = 1; maximumZoomScale = 5
            showsHorizontalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            addSubview(picture)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoomTap(_:)))
            doubleTap.numberOfTapsRequired = 2; addGestureRecognizer(doubleTap)
            picture.accessibilityLabel = "图片，双指缩放，双击放大或还原"; picture.isAccessibilityElement = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(url: URL, longMode: Bool) {
            guard loadedURL != url || self.longMode != longMode else { return }
            loadedURL = url; self.longMode = longMode
            loadTask?.cancel()
            picture.image = nil
            loadTask = Task { [weak self] in
                let decoded = await Task.detached(priority: .userInitiated) { ImageDecoder.decode(url) }.value
                guard !Task.isCancelled, let self, self.loadedURL == url else { return }
                self.picture.image = decoded
                self.lastSize = .zero
                self.setNeedsLayout()
            }
            lastSize = .zero; setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != lastSize, bounds.width > 0, bounds.height > 0, let image = picture.image else { return }
            lastSize = bounds.size
            setZoomScale(1, animated: false)
            let scale = longMode ? bounds.width / image.size.width : min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            picture.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            centerImage()
        }
        private func centerImage() { contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0) }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
        @objc private func zoomTap(_ tap: UITapGestureRecognizer) {
            if zoomScale > 1 { setZoomScale(1, animated: true) }
            else { let point = tap.location(in: picture); let size = CGSize(width: bounds.width / 3, height: bounds.height / 3); zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true) }
        }
    }
}

private enum ImageDecoder {
    static func decode(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Double ?? 1
        let height = properties?[kCGImagePropertyPixelHeight] as? Double ?? 1
        let count = CGImageSourceGetCount(source)
        let frames = count > 1 && count <= 150 ? count : 1
        // Limit total decoded pixels to 24 MP; keep originals intact for export.
        let scale = min(1, sqrt(24_000_000 / max(1, width * height * Double(frames))))
        let maxSize = min(24_000, max(width, height) * scale)
        let options: CFDictionary = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxSize] as CFDictionary
        var images: [UIImage] = []
        var duration = 0.0
        for index in 0..<frames {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            images.append(UIImage(cgImage: image))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
            duration += max(delay, 0.02)
        }
        guard frames > 1 else { return images.first }
        return UIImage.animatedImage(with: images, duration: duration)
    }
}
