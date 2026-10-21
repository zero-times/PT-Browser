import SwiftUI

struct ImageReadingRequest: Equatable {
    let id = UUID()
    let target: String
}

private struct ReadingPosition: Equatable {
    let id: String
    let top: CGFloat
    let bottom: CGFloat
}

private struct ReadingPositionsKey: PreferenceKey {
    static var defaultValue: [ReadingPosition] = []
    static func reduce(value: inout [ReadingPosition], nextValue: () -> [ReadingPosition]) { value += nextValue() }
}

/// One outer scroll view owns vertical movement. Each row uses its natural image
/// aspect ratio; no per-image vertical scroller or screen-height paging interrupts it.
struct ContinuousImageReader: View {
    let items: [MediaItem]
    let startID: String
    @Binding var currentID: String?
    let request: ImageReadingRequest?
    @State private var positioned = false
    @State private var zoom: ReadingZoom?
    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 12) {
                        ForEach(items) { item in
                            ReadingImageRow(item: item, width: viewport.size.width) { url in
                                zoom = ReadingZoom(id: item.id, name: item.name, url: url)
                            }
                            .id(item.id)
                            .background {
                                GeometryReader { geometry in
                                    let frame = geometry.frame(in: .named("ContinuousImages"))
                                    Color.clear.preference(key: ReadingPositionsKey.self, value: [ReadingPosition(id: item.id, top: frame.minY, bottom: frame.maxY)])
                                }
                            }
                        }
                    }
                }
                .coordinateSpace(name: "ContinuousImages")
                .accessibilityIdentifier("continuousImageList")
                .onPreferenceChange(ReadingPositionsKey.self) { positions in
                    guard positioned else { return }
                    let visible = positions.filter { $0.bottom > 1 && $0.top < viewport.size.height }.sorted { $0.top < $1.top }
                    if let leading = visible.first, currentID != leading.id { currentID = leading.id }
                }
                .task {
                    await Task.yield()
                    proxy.scrollTo(startID, anchor: .top)
                    await Task.yield()
                    positioned = true
                }
                .onChange(of: request) { _, value in
                    guard let value else { return }
                    withAnimation { proxy.scrollTo(value.target, anchor: .top) }
                }
            }
        }
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

private struct ReadingImageRow: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    let width: CGFloat
    let zoom: (URL) -> Void
    @State private var image: UIImage?
    @State private var resolvedURL: URL?
    @State private var aspect = CGFloat(1)
    @State private var error: String?
    var body: some View {
        Group {
            if let image, let resolvedURL {
                Button { zoom(resolvedURL) } label: {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: width, height: width * aspect)
                }.buttonStyle(.plain)
                    .accessibilityLabel(item.name)
                    .accessibilityHint("点按放大，可在列表中连续上下滚动")
                    .accessibilityIdentifier("readingImage-\(item.name)")
            } else if let error {
                ContentUnavailableView("无法读取图片", systemImage: "photo.badge.exclamationmark", description: Text(error))
                    .frame(width: width, height: max(180, width * aspect))
            } else {
                ProgressView("正在读取图片…").frame(width: width, height: width * aspect)
            }
        }
        .task(id: "\(item.id)-\(library.generation)") {
            do {
                let url = try await library.repository.playableURL(item)
                guard !Task.isCancelled else { return }
                let decoded = await Task.detached(priority: .userInitiated) { ImageDecoder.decode(url) }.value
                guard !Task.isCancelled else { return }
                guard let decoded else { throw PTError.message("iOS 无法解码此图片") }
                aspect = decoded.size.height / max(1, decoded.size.width)
                resolvedURL = url; image = decoded; error = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { image = nil; resolvedURL = nil }
    }
}
