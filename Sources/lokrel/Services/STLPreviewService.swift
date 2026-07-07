import AppKit
import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO

enum ModelPreviewService {
    static func makeScene(fileURL: URL) throws -> SCNScene {
        if fileURL.pathExtension.lowercased() == "obj" {
            return try makeOBJScene(fileURL: fileURL)
        }
        return try makeSTLScene(fileURL: fileURL)
    }

    private static func makeSTLScene(fileURL: URL) throws -> SCNScene {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let mesh = try parse(data: data)

        let vertexSource = SCNGeometrySource(vertices: mesh.vertices)
        let normalSource = SCNGeometrySource(normals: mesh.normals)
        var indices = Array(UInt32(0)..<UInt32(mesh.vertices.count))
        let indexData = indices.withUnsafeMutableBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: mesh.vertices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.18, green: 0.58, blue: 0.72, alpha: 1)
        material.roughness.contents = 0.72
        material.metalness.contents = 0.02
        material.isDoubleSided = true
        geometry.materials = [material]

        let modelNode = SCNNode(geometry: geometry)
        modelNode.name = "model"
        return preparedScene(modelNode: modelNode, minimum: mesh.minimum, maximum: mesh.maximum)
    }

    private static func makeOBJScene(fileURL: URL) throws -> SCNScene {
        guard MDLAsset.canImportFileExtension("obj") else { throw ModelPreviewError.unsupportedFile }
        let asset = MDLAsset(url: fileURL)
        guard asset.count > 0 else { throw ModelPreviewError.invalidFile }
        let importedScene = SCNScene(mdlAsset: asset)
        let modelNode = SCNNode()
        modelNode.name = "model"
        for child in importedScene.rootNode.childNodes {
            child.removeFromParentNode()
            modelNode.addChildNode(child)
        }
        let bounds = modelNode.boundingBox
        let minimum = bounds.min
        let maximum = bounds.max
        guard minimum.x.isFinite, minimum.y.isFinite, minimum.z.isFinite,
              maximum.x.isFinite, maximum.y.isFinite, maximum.z.isFinite else {
            throw ModelPreviewError.invalidFile
        }
        return preparedScene(modelNode: modelNode, minimum: minimum, maximum: maximum)
    }

    private static func preparedScene(
        modelNode: SCNNode,
        minimum: SCNVector3,
        maximum: SCNVector3
    ) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.controlBackgroundColor
        let center = SCNVector3(
            (minimum.x + maximum.x) / 2,
            (minimum.y + maximum.y) / 2,
            (minimum.z + maximum.z) / 2
        )
        modelNode.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(modelNode)

        let width = maximum.x - minimum.x
        let height = maximum.y - minimum.y
        let depth = maximum.z - minimum.z
        let maximumDimension = max(max(width, height), max(depth, 0.001))

        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(maximumDimension * 1.35)
        camera.zNear = 0.001
        camera.zFar = Double(maximumDimension * 20)
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(
            maximumDimension * 1.7,
            maximumDimension * 1.3,
            maximumDimension * 1.7
        )
        let targetNode = SCNNode()
        targetNode.name = "cameraTarget"
        scene.rootNode.addChildNode(targetNode)
        let lookAt = SCNLookAtConstraint(target: targetNode)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]
        scene.rootNode.addChildNode(cameraNode)

        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 1_100
        keyLight.eulerAngles = SCNVector3(-0.8, 0.6, 0)
        scene.rootNode.addChildNode(keyLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.intensity = 500
        fillLight.eulerAngles = SCNVector3(0.5, -2.2, 0)
        scene.rootNode.addChildNode(fillLight)

        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 350
        ambientLight.light?.color = NSColor(calibratedWhite: 0.82, alpha: 1)
        scene.rootNode.addChildNode(ambientLight)

        return scene
    }

    static func cachedThumbnail(fileURL: URL, projectID: String) throws -> String {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let size = values?.fileSize ?? 0
        let folder = try thumbnailFolder()
        let destination = folder.appendingPathComponent("\(projectID)-\(stamp)-\(size).png")
        if FileManager.default.fileExists(atPath: destination.path) { return destination.path }

        let scene = try makeScene(fileURL: fileURL)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        let image = renderer.snapshot(
            atTime: 0,
            with: CGSize(width: 512, height: 384),
            antialiasingMode: .multisampling4X
        )
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ModelPreviewError.couldNotRender
        }

        let oldFiles = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(projectID + "-") }
        for oldFile in oldFiles { try? FileManager.default.removeItem(at: oldFile) }
        try png.write(to: destination, options: .atomic)
        return destination.path
    }

    private static func parse(data: Data) throws -> STLMesh {
        if let binary = try parseBinaryIfPossible(data: data) { return binary }
        return try parseASCII(data: data)
    }

    private static func parseBinaryIfPossible(data: Data) throws -> STLMesh? {
        guard data.count >= 84 else { return nil }
        let triangleCount = Int(data.uint32LittleEndian(at: 80))
        guard triangleCount > 0 else { return nil }
        guard triangleCount <= (data.count - 84) / 50 else { return nil }
        guard triangleCount <= 5_000_000 else { throw ModelPreviewError.tooManyTriangles }

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        vertices.reserveCapacity(triangleCount * 3)
        normals.reserveCapacity(triangleCount * 3)
        var bounds = Bounds()

        for triangle in 0..<triangleCount {
            let offset = 84 + triangle * 50
            var normal = data.vector3(at: offset)
            let a = data.vector3(at: offset + 12)
            let b = data.vector3(at: offset + 24)
            let c = data.vector3(at: offset + 36)
            if normal.lengthSquared < 0.000_000_1 { normal = faceNormal(a, b, c) }
            vertices.append(contentsOf: [a, b, c])
            normals.append(contentsOf: [normal, normal, normal])
            bounds.include(a)
            bounds.include(b)
            bounds.include(c)
        }
        return try STLMesh(vertices: vertices, normals: normals, bounds: bounds)
    }

    private static func parseASCII(data: Data) throws -> STLMesh {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else {
            throw ModelPreviewError.invalidFile
        }
        var vertices: [SCNVector3] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 4, parts[0].lowercased() == "vertex",
                  let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) else {
                continue
            }
            vertices.append(SCNVector3(x, y, z))
        }
        guard !vertices.isEmpty, vertices.count.isMultiple(of: 3) else {
            throw ModelPreviewError.invalidFile
        }
        guard vertices.count / 3 <= 5_000_000 else { throw ModelPreviewError.tooManyTriangles }

        var normals: [SCNVector3] = []
        var bounds = Bounds()
        normals.reserveCapacity(vertices.count)
        for index in stride(from: 0, to: vertices.count, by: 3) {
            let normal = faceNormal(vertices[index], vertices[index + 1], vertices[index + 2])
            normals.append(contentsOf: [normal, normal, normal])
            bounds.include(vertices[index])
            bounds.include(vertices[index + 1])
            bounds.include(vertices[index + 2])
        }
        return try STLMesh(vertices: vertices, normals: normals, bounds: bounds)
    }

    private static func faceNormal(_ a: SCNVector3, _ b: SCNVector3, _ c: SCNVector3) -> SCNVector3 {
        let ab = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z)
        let ac = SCNVector3(c.x - a.x, c.y - a.y, c.z - a.z)
        let cross = SCNVector3(
            ab.y * ac.z - ab.z * ac.y,
            ab.z * ac.x - ab.x * ac.z,
            ab.x * ac.y - ab.y * ac.x
        )
        let length = sqrt(cross.lengthSquared)
        guard length > 0 else { return SCNVector3(0, 1, 0) }
        return SCNVector3(cross.x / length, cross.y / length, cross.z / length)
    }

    private static func thumbnailFolder() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base
            .appendingPathComponent("lokrel", isDirectory: true)
            .appendingPathComponent("ModelThumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private struct STLMesh {
    let vertices: [SCNVector3]
    let normals: [SCNVector3]
    let minimum: SCNVector3
    let maximum: SCNVector3

    init(vertices: [SCNVector3], normals: [SCNVector3], bounds: Bounds) throws {
        guard let minimum = bounds.minimum, let maximum = bounds.maximum else {
            throw ModelPreviewError.invalidFile
        }
        self.vertices = vertices
        self.normals = normals
        self.minimum = minimum
        self.maximum = maximum
    }
}

private struct Bounds {
    var minimum: SCNVector3?
    var maximum: SCNVector3?

    mutating func include(_ point: SCNVector3) {
        if let currentMinimum = minimum, let currentMaximum = maximum {
            minimum = SCNVector3(
                min(currentMinimum.x, point.x),
                min(currentMinimum.y, point.y),
                min(currentMinimum.z, point.z)
            )
            maximum = SCNVector3(
                max(currentMaximum.x, point.x),
                max(currentMaximum.y, point.y),
                max(currentMaximum.z, point.z)
            )
        } else {
            minimum = point
            maximum = point
        }
    }
}

private enum ModelPreviewError: LocalizedError {
    case invalidFile
    case tooManyTriangles
    case couldNotRender
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "This 3D model could not be read."
        case .tooManyTriangles: return "This 3D model is too large to preview."
        case .couldNotRender: return "The 3D model preview could not be rendered."
        case .unsupportedFile: return "This 3D model format is not supported for preview."
        }
    }
}

private extension Data {
    func uint32LittleEndian(at offset: Int) -> UInt32 {
        withUnsafeBytes { rawBuffer in
            UInt32(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    func floatLittleEndian(at offset: Int) -> Float {
        Float(bitPattern: uint32LittleEndian(at: offset))
    }

    func vector3(at offset: Int) -> SCNVector3 {
        SCNVector3(
            floatLittleEndian(at: offset),
            floatLittleEndian(at: offset + 4),
            floatLittleEndian(at: offset + 8)
        )
    }
}

private extension SCNVector3 {
    var lengthSquared: CGFloat {
        let xSquared = x * x
        let ySquared = y * y
        let zSquared = z * z
        return xSquared + ySquared + zSquared
    }
}
