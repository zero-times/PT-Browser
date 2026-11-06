import SwiftUI
import AVFoundation
import ImageIO

actor ThumbnailService {
    static let shared = ThumbnailService()
    func image(url: URL, kind: MediaKind) async -> UIImage? {
        if kind == .image {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
        if kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            if let result = try? await generator.image(at: .zero) { return UIImage(cgImage: result.image) }
        }
        return nil
    }
}

struct MediaThumbnail: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(.tertiarySystemFill)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else { Image(systemName: item.kind.icon).font(.largeTitle).foregroundStyle(.secondary) }
                badges
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
        }
        .task(id: "\(library.generation)-\(item.id)") {
            image = nil
            let repository = library.repository
            if let url = try? await repository.playableURL(item), !Task.isCancelled {
                let loaded = await ThumbnailService.shared.image(url: url, kind: item.kind)
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
        .accessibilityHidden(true)
    }
    private var badges: some View {
        VStack {
            HStack {
                if item.favorite { Image(systemName: "heart.fill").foregroundStyle(.white).shadow(radius: 2) }
                Spacer()
                if item.isEncrypted { Image(systemName: "lock.fill").foregroundStyle(.white).shadow(radius: 2) }
            }
            Spacer()
            if item.kind != .image { HStack { Image(systemName: item.kind.icon); Spacer(); Text(item.byteLabel) }.font(.caption2).foregroundStyle(.white).padding(6).background(.black.opacity(0.5)) }
        }.padding(8)
    }
}
