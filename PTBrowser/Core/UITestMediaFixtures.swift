#if DEBUG
import UIKit

/// Only opt-in UI tests seed the disposable UITestLibrary. Release builds contain no fixture code.
@MainActor enum UITestMediaFixtures {
    static func seed(_ root: URL) throws {
        if let encoded = ProcessInfo.processInfo.environment["PT_UI_FIXTURE_VIDEO"], let video = Data(base64Encoded: encoded) {
            try video.write(to: root.appendingPathComponent("Fullscreen-Test.mp4"))
        }
        for index in 1...8 {
            let size = CGSize(width: 240, height: index % 3 == 1 ? 720 : 240)
            let data = UIGraphicsImageRenderer(size: size).pngData { context in
                UIColor(hue: CGFloat(index) / 10, saturation: 0.5, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                ("Image \(index)" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.white])
            }
            let file = root.appendingPathComponent("Image-\(index).png")
            try data.write(to: file)
            // Stable ordering allows the continuous-reader test to begin with Image-1.
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: TimeInterval(1000 - index))], ofItemAtPath: file.path)
        }
        if ProcessInfo.processInfo.arguments.contains("-library-ui-fixtures") {
            for name in ["Wide-1.png", "Wide-2.png", "Hidden-Wide.png", "Hidden-Tall.png"] {
                let size = CGSize(width: 1600, height: name.contains("Tall") ? 4800 : 160)
                let data = UIGraphicsImageRenderer(size: size).pngData { context in
                    UIColor.systemOrange.setFill(); context.fill(CGRect(origin: .zero, size: size))
                    UIColor.systemBlue.setFill(); context.fill(CGRect(x: 720, y: 0, width: 160, height: size.height))
                }
                try data.write(to: root.appendingPathComponent(name))
            }
            let video = root.appendingPathComponent("Fullscreen-Test.mp4")
            if FileManager.default.fileExists(atPath: video.path) {
                try FileManager.default.copyItem(at: video, to: root.appendingPathComponent("Hidden-Video.mp4"))
            }
            var audio = Data("RIFF".utf8)
            func append(_ value: UInt32, bytes: Int) { for shift in 0..<bytes { audio.append(UInt8((value >> (shift * 8)) & 255)) } }
            append(836, bytes: 4); audio.append(Data("WAVEfmt ".utf8))
            append(16, bytes: 4); append(1, bytes: 2); append(1, bytes: 2)
            append(8000, bytes: 4); append(8000, bytes: 4); append(1, bytes: 2); append(8, bytes: 2)
            audio.append(Data("data".utf8)); append(800, bytes: 4); audio.append(Data(repeating: 128, count: 800))
            try audio.write(to: root.appendingPathComponent("Hidden-Audio.wav"))
            for (name, seconds) in [("Wide-1.png", 1792627202.0), ("Wide-2.png", 1792627201),
                                    ("Hidden-Wide.png", 1792540800), ("Hidden-Video.mp4", 1792540800),
                                    ("Hidden-Tall.png", 1792454400), ("Hidden-Audio.wav", 1792368000)] {
                try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: root.appendingPathComponent(name).path)
            }
        }
    }
    static func seedVault(_ repository: LibraryRepository) async throws {
        try await repository.createVault(password: "ui-password-123")
        for item in try await repository.snapshot().items where item.name.hasPrefix("Hidden-") { try await repository.encrypt(item) }
    }
    static func downloadHistory() -> [DownloadJob] {
        [.completed, .failed, .paused].map { state in
            DownloadJob(id: UUID(), url: URL(string: "https://example.invalid/fixture.mp4")!, name: "\(state.rawValue)-fixture.mp4", kind: .video, isHLS: false, page: nil, state: state, destination: Data(), destinationName: "UITestLibrary")
        }
    }

}
#endif
