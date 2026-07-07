import SceneKit
import SwiftUI

struct ModelPreviewView: View {
    let fileURL: URL
    @State private var scene: SCNScene?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let scene {
                SceneKitContainer(scene: scene)
            } else if loadFailed {
                ContentUnavailableView("Preview Unavailable", systemImage: "cube.transparent")
            } else {
                ProgressView("Loading 3D preview…")
            }
        }
        .task(id: fileURL) {
            scene = nil
            loadFailed = false
            do {
                scene = try await Task.detached(priority: .userInitiated) {
                    try ModelPreviewService.makeScene(fileURL: fileURL)
                }.value
            } catch {
                loadFailed = true
            }
        }
    }
}

private struct SceneKitContainer: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .controlBackgroundColor
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard view.scene !== scene else { return }
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
    }
}
