import SwiftUI

struct ImageReadingRequest: Equatable {
    let id = UUID()
    let target: String
}

struct ContinuousImageReader: View {
    @EnvironmentObject private var library: LibraryStore
    let items: [MediaItem]
    let startID: String
    @Binding var currentID: String?
    let request: ImageReadingRequest?
    @State private var zoom: ReadingZoom?
    var body: some View {
        ReadingScrollContent(items: items, startID: startID, request: request,
                             repository: library.repository, generation: library.generation,
                             selected: { currentID = $0 },
                             zoom: { zoom = ReadingZoom(id: $0.id, name: $0.name, url: $1) })
            .sheet(item: $zoom) { image in
                NavigationStack {
                    ZoomableImage(url: image.url, longMode: true)
                        .background(.black)
                        .navigationTitle(image.name).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { zoom = nil } } }
                }.preferredColorScheme(.dark)
            }
    }
}

private struct ReadingZoom: Identifiable {
    let id: String
    let name: String
    let url: URL
}

/// Explicit row geometry avoids LazyVStack's estimated heights and scroll corrections.
/// Pixel data can be evicted independently of these sizes.
struct ImageReadingLayout {
    struct Anchor {
        let index: Int
        let distance: CGFloat
    }
    private(set) var frames: [CGRect] = []
    private(set) var height: CGFloat = 0
    mutating func rebuild(width: CGFloat, aspects: [CGFloat]) {
        var y: CGFloat = 0
        frames = aspects.map { aspect in
            let rect = CGRect(x: 0, y: y, width: width, height: width * aspect)
            y = rect.maxY
            return rect
        }
        height = y
    }
    func indices(in rect: CGRect) -> Range<Int> {
        // Binary search keeps scrolling cheap even for very large libraries.
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY <= rect.minY { low = mid + 1 } else { high = mid }
        }
        let start = low
        while low < frames.count && frames[low].minY < rect.maxY { low += 1 }
        return start..<low
    }
    func anchor(at y: CGFloat) -> Anchor? {
        guard !frames.isEmpty else { return nil }
        let index = min(indices(in: CGRect(x: 0, y: max(0, y), width: 1, height: 1)).lowerBound, frames.count - 1)
        return Anchor(index: index, distance: y - frames[index].minY)
    }
    func offset(for anchor: Anchor, scale: CGFloat = 1) -> CGFloat {
        guard frames.indices.contains(anchor.index) else { return 0 }
        return frames[anchor.index].minY + anchor.distance * scale
    }
}

private struct ReadingScrollContent: UIViewRepresentable {
    let items: [MediaItem]
    let startID: String
    let request: ImageReadingRequest?
    let repository: LibraryRepository
    let generation: UUID
    let selected: (String) -> Void
    let zoom: (MediaItem, URL) -> Void
    func makeUIView(context: Context) -> ImageReadingScrollView { ImageReadingScrollView() }
    func updateUIView(_ view: ImageReadingScrollView, context: Context) {
        view.selected = selected; view.zoom = zoom
        view.configure(items: items, startID: startID, repository: repository, generation: generation)
        view.navigate(request)
    }
    static func dismantleUIView(_ view: ImageReadingScrollView, coordinator: ()) { view.clear() }
}

final class ImageReadingScrollView: UIScrollView, UIScrollViewDelegate {
    var selected: ((String) -> Void)?
    var zoom: ((MediaItem, URL) -> Void)?
    private var items: [MediaItem] = []
    private var aspects: [CGFloat] = []
    private var geometry = ImageReadingLayout()
    private var tiles: [Int: ReadingImageTile] = [:]
    private var loads: [Int: Task<Void, Never>] = [:]
    private var loadIDs: [Int: UUID] = [:]
    private var repository: LibraryRepository?
    private var generation: UUID?
    private var session = UUID()
    private var lastSize = CGSize.zero
    private var pendingStart: String?
    private var lastRequest: UUID?
    private var reportedID: String?
    private var layingOut = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        alwaysBounceVertical = true
        isDirectionalLockEnabled = true
        accessibilityIdentifier = "continuousImageList"
        NotificationCenter.default.addObserver(self, selector: #selector(releaseDistantImages), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(items: [MediaItem], startID: String, repository: LibraryRepository, generation: UUID) {
        guard self.items != items || self.repository !== repository || self.generation != generation else { return }
        clear()
        self.items = items; self.repository = repository; self.generation = generation
        geometry = ImageReadingLayout()
        aspects = Array(repeating: 1, count: items.count)
        pendingStart = startID; lastRequest = nil; reportedID = nil
        lastSize = .zero
        setNeedsLayout()
    }
    func clear() {
        session = UUID()
        loads.values.forEach { $0.cancel() }; loads.removeAll(); loadIDs.removeAll()
        tiles.values.forEach { $0.removeFromSuperview() }; tiles.removeAll()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !layingOut, bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != lastSize {
            let oldWidth = lastSize.width
            lastSize = bounds.size
            rebuild(scale: oldWidth > 0 ? bounds.width / oldWidth : 1)
        }
        if let target = pendingStart, let index = items.firstIndex(where: { $0.id == target }) {
            pendingStart = nil
            setContentOffset(CGPoint(x: 0, y: min(geometry.frames[index].minY, max(0, contentSize.height - bounds.height))), animated: false)
        }
        updateTiles()
    }
    private func rebuild(scale: CGFloat = 1) {
        let anchor = geometry.anchor(at: contentOffset.y)
        layingOut = true
        geometry.rebuild(width: bounds.width, aspects: aspects)
        contentSize = CGSize(width: bounds.width, height: geometry.height)
        if let anchor {
            // A newly decoded image above the viewport must not move the image
            // under the reader's finger. Rotation also preserves the relative point.
            let anchoredY = geometry.offset(for: anchor, scale: scale)
            // Keep native rubber-banding while the user is still dragging.
            let y = isTracking || isDecelerating ? anchoredY : min(max(0, anchoredY), max(0, geometry.height - bounds.height))
            if abs(y - contentOffset.y) > 0.5 { contentOffset = CGPoint(x: 0, y: y) }
        }
        for (index, tile) in tiles { tile.frame = geometry.frames[index] }
        layingOut = false
    }
    func navigate(_ request: ImageReadingRequest?) {
        guard let request, request.id != lastRequest,
              let index = items.firstIndex(where: { $0.id == request.target }), geometry.frames.indices.contains(index) else { return }
        lastRequest = request.id
        let y = min(geometry.frames[index].minY, max(0, contentSize.height - bounds.height))
        setContentOffset(CGPoint(x: 0, y: y), animated: !UIAccessibility.isReduceMotionEnabled)
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !layingOut else { return }
        updateTiles()
    }
    private func updateTiles() {
        guard !layingOut, bounds.height > 0, !geometry.frames.isEmpty else { return }
        let visible = geometry.indices(in: bounds)
        let nearby = geometry.indices(in: bounds.insetBy(dx: 0, dy: -bounds.height * 2))
        for index in Array(tiles.keys) where !nearby.contains(index) {
            tiles.removeValue(forKey: index)?.removeFromSuperview()
            loads.removeValue(forKey: index)?.cancel(); loadIDs.removeValue(forKey: index)
        }
        for index in nearby where tiles[index] == nil {
            let tile = ReadingImageTile(name: items[index].name)
            tile.frame = geometry.frames[index]
            tile.addAction(UIAction { [weak self, weak tile] _ in
                guard let self, let url = tile?.url else { return }
                self.zoom?(self.items[index], url)
            }, for: .touchUpInside)
            addSubview(tile); tiles[index] = tile
        }
        if let index = visible.first, items[index].id != reportedID {
            reportedID = items[index].id
            let id = items[index].id, currentSession = session
            // Do not mutate SwiftUI bindings during updateUIView/layoutSubviews.
            Task { @MainActor [weak self] in
                guard let self, self.session == currentSession, self.reportedID == id else { return }
                self.selected?(id)
            }
        }
        // Decode at most two images concurrently, prioritizing visible images.
        // Keep two screens on either side warm for continuous dragging and reversal.
        let candidates = nearby.sorted {
            let left = visible.contains($0), right = visible.contains($1)
            if left != right { return left }
            return abs(geometry.frames[$0].midY - bounds.midY) < abs(geometry.frames[$1].midY - bounds.midY)
        }
        for index in candidates where loads.count < 2 && tiles[index]?.needsImage == true && loads[index] == nil { load(index) }
    }
    private func load(_ index: Int) {
        guard let repository else { return }
        let item = items[index], token = UUID(), currentSession = session
        let pixelWidth = bounds.width * (window?.screen.scale ?? traitCollection.displayScale)
        loadIDs[index] = token
        loads[index] = Task { [weak self] in
            do {
                let url = try await repository.playableURL(item)
                try Task.checkCancellation()
                let work = Task.detached(priority: .userInitiated) {
                    ImageDecoder.decode(url, targetPixelWidth: pixelWidth)
                }
                let decoded = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard let self, self.session == currentSession, self.loadIDs[index] == token else { return }
                guard let decoded else { throw PTError.message("iOS 无法解码此图片") }
                let aspect = decoded.size.height / max(1, decoded.size.width)
                if abs(self.aspects[index] - aspect) > 0.0001 {
                    self.aspects[index] = aspect
                    self.rebuild()
                }
                self.tiles[index]?.display(decoded, url: url)
                self.finish(index)
            } catch {
                guard !Task.isCancelled, let self, self.session == currentSession, self.loadIDs[index] == token else { return }
                self.tiles[index]?.displayError(error.localizedDescription)
                self.finish(index)
            }
        }
    }
    private func finish(_ index: Int) {
        loads.removeValue(forKey: index); loadIDs.removeValue(forKey: index)
        updateTiles()
    }
    @objc private func releaseDistantImages() {
        let visible = geometry.indices(in: bounds)
        for index in Array(tiles.keys) where !visible.contains(index) {
            tiles.removeValue(forKey: index)?.removeFromSuperview()
            loads.removeValue(forKey: index)?.cancel(); loadIDs.removeValue(forKey: index)
        }
    }
}

private final class ReadingImageTile: UIControl {
    private let picture = UIImageView()
    private let status = UILabel()
    private(set) var url: URL?
    private(set) var needsImage = true
    init(name: String) {
        super.init(frame: .zero)
        picture.contentMode = .scaleToFill
        addSubview(picture)
        status.text = "正在读取图片…"; status.textColor = .secondaryLabel
        status.font = .preferredFont(forTextStyle: .caption1)
        status.adjustsFontForContentSizeCategory = true; status.numberOfLines = 0; status.textAlignment = .center
        addSubview(status)
        isAccessibilityElement = true; accessibilityTraits = .button
        accessibilityLabel = name; accessibilityHint = "点按放大，可在列表中连续上下滚动"
        accessibilityIdentifier = "readingImage-\(name)"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = bounds
        status.frame = bounds.insetBy(dx: 16, dy: 16)
    }
    func display(_ image: UIImage, url: URL) {
        picture.image = image; self.url = url; status.isHidden = true; needsImage = false
        accessibilityValue = "已加载"
    }
    func displayError(_ error: String) {
        status.text = "无法读取图片\n\(error)"; needsImage = false
        accessibilityValue = status.text
    }
}
