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
    }
    static func downloadHistory() -> [DownloadJob] {
        [.completed, .failed, .paused].map { state in
            DownloadJob(id: UUID(), url: URL(string: "https://example.invalid/fixture.mp4")!, name: "\(state.rawValue)-fixture.mp4", kind: .video, isHLS: false, page: nil, state: state, destination: Data(), destinationName: "UITestLibrary")
        }
    }

}
#endif
