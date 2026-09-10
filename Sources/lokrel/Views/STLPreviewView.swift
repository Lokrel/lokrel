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
                ContentUnavailableView(L10n.text("Preview Unavailable"), systemImage: "cube.transparent")
            } else {
                ProgressView(L10n.text("Loading 3D preview…"))
            }
        }
        .task(id: fileURL) {
            scene = nil
            loadFailed = false
            do {
                let loadedScene = try await Task.detached(priority: .userInitiated) {
                    try ModelPreviewService.makeScene(fileURL: fileURL)
                }.value
                guard !Task.isCancelled else { return }
                scene = loadedScene
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
    }
}

private struct SceneKitContainer: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let view = ZoomingSceneView()
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

private final class ZoomingSceneView: SCNView {
    override func scrollWheel(with event: NSEvent) {
        guard let camera = pointOfView?.camera, camera.usesOrthographicProjection else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
        camera.orthographicScale = max(0.001, camera.orthographicScale * exp(-max(-1, min(1, delta))))
    }
}
