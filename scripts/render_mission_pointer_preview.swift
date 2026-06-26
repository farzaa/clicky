import AppKit
import SwiftUI

@main
struct MissionPointerPreviewRenderer {
    @MainActor
    static func main() throws {
        let outputPath = CommandLine.arguments.dropFirst().first
            ?? "/tmp/spider-mission-pointer-preview.png"
        let outputURL = URL(fileURLWithPath: outputPath)

        let content = ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.96),
                    Color(red: 0.03, green: 0.08, blue: 0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GuideClickTargetView(
                label: "Leads",
                missionAlignment: "Matches selected mission"
            )
        }
        .frame(width: 360, height: 260)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SpiderMissionPointerPreview", code: 1)
        }

        try pngData.write(to: outputURL, options: .atomic)
    }
}
