import AppKit

struct ModelDragContent {
    let projectIDs: [String]
    let files: [URL]
    let requiresFileChoice: Bool

    init(projects: [ModelProject]) {
        projectIDs = projects.map(\.id)
        requiresFileChoice = projects.contains { $0.files.filter(\.isPrimaryModel).count != 1 }
        files = requiresFileChoice ? [] : projects.compactMap { $0.primaryFile?.url }
    }

    init(projectID: String, file: URL) {
        projectIDs = [projectID]
        files = [file]
        requiresFileChoice = false
    }

    func pasteboardItems() -> [NSPasteboardItem] {
        let items = (files.isEmpty ? [nil] : files.map(Optional.some)).map { url in
            let item = NSPasteboardItem()
            if let url { item.setString(url.absoluteString, forType: .fileURL) }
            return item
        }
        items.first?.setString(projectIDs.joined(separator: "\n"), forType: .string)
        return items
    }

    static func fileKey(projectID: String, fileID: Int64) -> String { "file:\(projectID):\(fileID)" }
    static func fileChoice(_ key: String) -> (projectID: String, fileID: Int64)? {
        let parts = key.split(separator: ":")
        guard parts.count == 3, parts[0] == "file", let id = Int64(parts[2]) else { return nil }
        return (String(parts[1]), id)
    }
}
