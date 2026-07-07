import Foundation

enum LibraryScanner {
    private static let modelExtensions: Set<String> = [
        "3mf", "stl", "step", "stp", "obj", "f3d", "iges", "igs"
    ]
    private static let companionExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "pdf", "md", "txt"
    ]

    static func scan(rootURL: URL) async throws -> ScanResult {
        try await Task.detached(priority: .userInitiated) {
            try scanSynchronously(rootURL: rootURL)
        }.value
    }

    static func scanSynchronously(rootURL: URL) throws -> ScanResult {
        let startedAt = Date()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isHiddenKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var filesByDirectory: [String: [ScannedFile]] = [:]
        var visitedFileCount = 0

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isHidden != true else { continue }
            visitedFileCount += 1

            let fileExtension = fileURL.pathExtension.lowercased()
            guard modelExtensions.contains(fileExtension)
                    || companionExtensions.contains(fileExtension) else { continue }

            let file = ScannedFile(
                path: fileURL.path,
                filename: fileURL.lastPathComponent,
                fileExtension: fileExtension,
                size: Int64(values?.fileSize ?? 0),
                createdAt: values?.creationDate,
                modifiedAt: values?.contentModificationDate
            )
            filesByDirectory[fileURL.deletingLastPathComponent().path, default: []].append(file)
        }

        var projects: [ScannedProject] = []
        let rootPath = rootURL.standardizedFileURL.path

        for (directoryPath, directoryFiles) in filesByDirectory {
            let modelFiles = directoryFiles.filter { modelExtensions.contains($0.fileExtension) }
            guard !modelFiles.isEmpty else { continue }

            var groups = Dictionary(grouping: modelFiles) { normalizedStem($0.filename) }
            let companions = directoryFiles.filter { companionExtensions.contains($0.fileExtension) }

            for companion in companions {
                let stem = normalizedStem(companion.filename)
                if groups[stem] != nil {
                    groups[stem, default: []].append(companion)
                } else if isReadme(companion.filename), groups.count == 1,
                          let onlyKey = groups.keys.first {
                    groups[onlyKey, default: []].append(companion)
                }
            }

            for (stem, files) in groups {
                let sortedFiles = files.sorted(by: fileSort)
                guard let representative = sortedFiles.first(where: {
                    $0.fileExtension == "3mf"
                }) ?? sortedFiles.first(where: {
                    modelExtensions.contains($0.fileExtension)
                }) else { continue }

                let relativeDirectory = relativePath(directoryPath, under: rootPath)
                let groupKey = relativeDirectory.lowercased() + "::" + stem
                let createdAt = files.compactMap(\.createdAt).min()
                let modifiedAt = files.compactMap(\.modifiedAt).max()

                projects.append(ScannedProject(
                    groupKey: groupKey,
                    name: URL(fileURLWithPath: representative.filename)
                        .deletingPathExtension().lastPathComponent,
                    directoryPath: directoryPath,
                    createdAt: createdAt,
                    modifiedAt: modifiedAt,
                    size: files.reduce(0) { $0 + $1.size },
                    files: sortedFiles
                ))
            }
        }

        return ScanResult(
            projects: projects.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            visitedFileCount: visitedFileCount,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private static func normalizedStem(_ filename: String) -> String {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private static func isReadme(_ filename: String) -> Bool {
        normalizedStem(filename) == "readme"
    }

    private static func relativePath(_ path: String, under rootPath: String) -> String {
        guard path != rootPath, path.hasPrefix(rootPath + "/") else { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func fileSort(_ lhs: ScannedFile, _ rhs: ScannedFile) -> Bool {
        let order = ["3mf", "step", "stp", "stl", "obj", "f3d", "iges", "igs",
                     "jpg", "jpeg", "png", "webp", "pdf", "md", "txt"]
        let leftIndex = order.firstIndex(of: lhs.fileExtension) ?? order.count
        let rightIndex = order.firstIndex(of: rhs.fileExtension) ?? order.count
        if leftIndex != rightIndex { return leftIndex < rightIndex }
        return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
    }
}
