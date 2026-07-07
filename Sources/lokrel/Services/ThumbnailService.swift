import Foundation
import ZIPFoundation

actor ThumbnailService {
    private var activeProjectIDs: Set<String> = []

    func previewThumbnail(for project: ModelProject) async throws -> String? {
        guard !activeProjectIDs.contains(project.id) else { return nil }
        activeProjectIDs.insert(project.id)
        defer { activeProjectIDs.remove(project.id) }

        return try await Task.detached(priority: .utility) {
            if let sourceFile = project.files.first(where: {
                $0.fileExtension.lowercased() == "3mf"
            }), let path = try? Self.extractEmbeddedThumbnail(
                sourceURL: sourceFile.url,
                projectID: project.id
            ) {
                return path
            }
            if let previewFile = project.files.first(where: {
                ["stl", "obj"].contains($0.fileExtension.lowercased())
            }) {
                return try ModelPreviewService.cachedThumbnail(
                    fileURL: previewFile.url,
                    projectID: project.id
                )
            }
            return nil
        }.value
    }

    nonisolated static func extractEmbeddedThumbnail(
        sourceURL: URL,
        projectID: String
    ) throws -> String? {
        let cacheFolder = try thumbnailCacheFolder()
        let archive = try Archive(url: sourceURL, accessMode: .read)

        let entries = archive.filter { entry in
            let path = entry.path.lowercased()
            return path.hasSuffix(".png") || path.hasSuffix(".jpg") || path.hasSuffix(".jpeg")
        }
        let entry = entries.sorted { lhs, rhs in
            thumbnailRank(lhs.path) < thumbnailRank(rhs.path)
        }.first
        guard let entry else { return nil }

        let entryExtension = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
        let safeExtension = ["png", "jpg", "jpeg"].contains(entryExtension)
            ? entryExtension : "png"
        let values = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let size = values?.fileSize ?? 0
        let destination = cacheFolder
            .appendingPathComponent("\(projectID)-\(stamp)-\(size)")
            .appendingPathExtension(safeExtension)

        if FileManager.default.fileExists(atPath: destination.path) {
            return destination.path
        }
        let oldFiles = try FileManager.default.contentsOfDirectory(
            at: cacheFolder,
            includingPropertiesForKeys: nil
        ).filter {
            $0.deletingPathExtension().lastPathComponent == projectID
                || $0.lastPathComponent.hasPrefix(projectID + "-")
        }
        for oldFile in oldFiles { try? FileManager.default.removeItem(at: oldFile) }
        _ = try archive.extract(entry, to: destination)
        return destination.path
    }

    func copyCustomCover(from sourceURL: URL, projectID: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let folder = try Self.coverCacheFolder()
            let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
            let destination = folder
                .appendingPathComponent(projectID)
                .appendingPathExtension(fileExtension)

            let fileManager = FileManager.default
            let existing = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            ).filter { $0.deletingPathExtension().lastPathComponent == projectID }
            for file in existing { try? fileManager.removeItem(at: file) }
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination.path
        }.value
    }

    private nonisolated static func thumbnailCacheFolder() throws -> URL {
        try cacheFolder(named: "Thumbnails")
    }

    private nonisolated static func coverCacheFolder() throws -> URL {
        try cacheFolder(named: "Covers")
    }

    private nonisolated static func cacheFolder(named name: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base
            .appendingPathComponent("lokrel", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private func thumbnailRank(_ path: String) -> Int {
    let normalized = path.lowercased()
    if normalized == "metadata/thumbnail.png" { return 0 }
    if normalized.hasSuffix("/thumbnail.png") { return 1 }
    if normalized.contains("thumbnail") { return 2 }
    if normalized.contains("preview") { return 3 }
    return 10
}
