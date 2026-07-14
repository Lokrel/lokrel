import AppKit
import SwiftUI

struct ProjectThumbnail: View {
    let project: ModelProject
    @ObservedObject var appModel: AppModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                Image(systemName: "cube.transparent")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: thumbnailTaskID) {
            guard !appModel.isScanning else { return }
            guard let url = project.displayCoverURL else {
                image = nil
                appModel.ensureThumbnail(for: project)
                return
            }
            image = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
        }
    }

    private var thumbnailTaskID: String {
        guard !appModel.isScanning else { return "scanning" }
        return project.displayCoverURL?.path ?? "automatic:\(project.id)"
    }
}
