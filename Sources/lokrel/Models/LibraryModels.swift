import Foundation

struct ModelFile: Identifiable, Hashable, Sendable {
    let id: Int64
    let path: String
    let filename: String
    let fileExtension: String
    let size: Int64
    let createdAt: Date?
    let modifiedAt: Date?

    var url: URL { URL(fileURLWithPath: path) }

    var displayType: String {
        fileExtension.isEmpty ? "FILE" : fileExtension.uppercased()
    }

    var isImage: Bool {
        ["jpg", "jpeg", "png", "webp"].contains(fileExtension.lowercased())
    }

    var isPrimaryModel: Bool {
        ["3mf", "stl", "step", "stp", "obj", "f3d", "iges", "igs"]
            .contains(fileExtension.lowercased())
    }
}

struct ModelProject: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let directoryPath: String
    let createdAt: Date?
    let modifiedAt: Date?
    let importedAt: Date?
    let size: Int64
    var favorite: Bool
    var note: String
    var customName: String?
    var author: String
    var sourceURL: String
    var license: String
    var modelDescription: String
    var coverOverridePath: String?
    var thumbnailPath: String?
    let files: [ModelFile]
    var tags: [String]

    var displayCoverURL: URL? {
        if let coverOverridePath, FileManager.default.fileExists(atPath: coverOverridePath) {
            return URL(fileURLWithPath: coverOverridePath)
        }
        if let image = files.first(where: \.isImage) {
            return image.url
        }
        if let thumbnailPath, FileManager.default.fileExists(atPath: thumbnailPath) {
            return URL(fileURLWithPath: thumbnailPath)
        }
        return nil
    }

    var primaryFile: ModelFile? {
        files.first(where: { $0.fileExtension.lowercased() == "3mf" })
            ?? files.first(where: \.isPrimaryModel)
    }

    var directoryURL: URL { URL(fileURLWithPath: directoryPath) }

    var displayName: String {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? name : trimmed
    }
}

struct EditableModelDetails: Equatable, Sendable {
    var customName: String
    var author: String
    var sourceURL: String
    var license: String
    var modelDescription: String
}

struct TagSnapshot: Sendable {
    let name: String
    let sortOrder: Int
    let projectIDs: [String]
}

struct MetadataEntry: Identifiable, Hashable, Sendable {
    let name: String
    let value: String

    var id: String { name + "\u{1f}" + value }
}

struct ExtractedModelMetadata: Hashable, Sendable {
    let entries: [MetadataEntry]

    func value(named names: String...) -> String? {
        for name in names {
            if let value = entries.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            })?.value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    var title: String? { value(named: "Title", "dc:title") }
    var designer: String? { value(named: "Designer", "creator", "dc:creator") }
    var license: String? { value(named: "LicenseTerms", "License") }
    var description: String? { value(named: "Description", "dc:description") }
    var sourceURL: String? {
        let directURL = entries.lazy.compactMap { entry -> String? in
            guard ["url", "source", "origin", "download"].contains(where: {
                entry.name.localizedCaseInsensitiveContains($0)
            }) else { return nil }
            return metadataURLs(in: entry.value).first
        }.first
        if let directURL { return directURL }

        let makerWorldURL = entries.lazy.compactMap { entry -> String? in
            guard ["DesignModelId", "MakerWorldModelId", "ModelId"].contains(where: {
                entry.name.caseInsensitiveCompare($0) == .orderedSame
            }) else { return nil }
            return makerWorldModelURL(from: entry.value)
        }.first
        if let makerWorldURL { return makerWorldURL }

        return entries.lazy
            .filter { entry in
                ["Description", "dc:description"].contains {
                    entry.name.caseInsensitiveCompare($0) == .orderedSame
                }
            }
            .flatMap { metadataURLs(in: $0.value) }
            .first(where: isUsefulSourceURL)
    }
}

struct LibraryLocation: Hashable, Sendable {
    let id: Int64
    let rootPath: String
    let name: String
    let lastScanAt: Date?
}

enum LibrarySection: Hashable {
    case all
    case favorites
    case recent
    case tag(String)
    case folder(String)
}

enum BrowserLayout: String, CaseIterable {
    case grid
    case list
}

enum ImportDateFilter: String, CaseIterable, Identifiable {
    case any
    case today
    case lastSevenDays
    case lastThirtyDays
    case earlier

    var id: Self { self }

    var title: String {
        switch self {
        case .any: return "Any Time"
        case .today: return "Today"
        case .lastSevenDays: return "Last 7 Days"
        case .lastThirtyDays: return "Last 30 Days"
        case .earlier: return "Earlier"
        }
    }
}

struct DirectoryNode: Identifiable, Hashable {
    let path: String
    let name: String
    let projectCount: Int
    let children: [DirectoryNode]

    var id: String { path }
    var optionalChildren: [DirectoryNode]? { children.isEmpty ? nil : children }

    static func build(rootPath: String, projects: [ModelProject]) -> DirectoryNode {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        var discoveredPaths: Set<String> = [root]
        var directCounts: [String: Int] = [:]

        for project in projects {
            var current = URL(fileURLWithPath: project.directoryPath).standardizedFileURL.path
            directCounts[current, default: 0] += 1
            while current != root, current.hasPrefix(root + "/") {
                discoveredPaths.insert(current)
                current = URL(fileURLWithPath: current).deletingLastPathComponent().path
            }
        }

        var childrenByParent: [String: [String]] = [:]
        for path in discoveredPaths where path != root {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            childrenByParent[parent, default: []].append(path)
        }

        func makeNode(path: String) -> DirectoryNode {
            let childPaths = (childrenByParent[path] ?? []).sorted {
                URL(fileURLWithPath: $0).lastPathComponent.localizedStandardCompare(
                    URL(fileURLWithPath: $1).lastPathComponent
                ) == .orderedAscending
            }
            return DirectoryNode(
                path: path,
                name: path == root
                    ? URL(fileURLWithPath: root).lastPathComponent
                    : URL(fileURLWithPath: path).lastPathComponent,
                projectCount: directCounts[path] ?? 0,
                children: childPaths.map(makeNode)
            )
        }

        return makeNode(path: root)
    }
}
