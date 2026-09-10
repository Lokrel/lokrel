import Foundation
import CryptoKit

enum LibraryScanner {
    private static let modelExtensions: Set<String> = [
        "3mf", "stl", "step", "stp", "obj", "f3d", "iges", "igs"
    ]
    private static let companionExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "pdf", "md", "txt"
    ]

    static func scan(rootURL: URL, trackedProjects: [ModelProject] = [], scopePaths: [String]? = nil, forceSources: Bool = false, deferUnreadableModels: Bool = false, progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanResult {
        try await Task.detached(priority: .userInitiated) {
            try scanSynchronously(rootURL: rootURL, trackedProjects: trackedProjects, scopePaths: scopePaths, forceSources: forceSources, deferUnreadableModels: deferUnreadableModels, progress: progress)
        }.value
    }

    static func scanSynchronously(rootURL: URL, trackedProjects: [ModelProject] = [], scopePaths: [String]? = nil, forceSources: Bool = false, deferUnreadableModels: Bool = false, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanResult {
        let rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let startedAt = Date()
        let rootValues = try rootURL.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true, FileManager.default.isReadableFile(atPath: rootURL.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var lastProgress = Date.distantPast
        var scanError: Error?
        func report(_ value: ScanProgress, force: Bool = false) {
            if force || Date().timeIntervalSince(lastProgress) >= 0.1 {
                progress(value)
                lastProgress = Date()
            }
        }
        report(ScanProgress(), force: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isHiddenKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]

        var filesByDirectory: [String: [ScannedFile]] = [:]
        var visitedFileCount = 0
        var directoryPaths: [String] = []

        for scope in scopePaths ?? [rootURL.path] {
            let scopeURL = URL(fileURLWithPath: scope)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: scope, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue, FileManager.default.isReadableFile(atPath: scope) else { throw CocoaError(.fileReadNoPermission) }
            if scope != rootURL.path { directoryPaths.append(scope) }
            guard let enumerator = FileManager.default.enumerator(
                at: scopeURL, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in scanError = error; return false }
            ) else { throw CocoaError(.fileReadNoSuchFile) }
        for case let enumeratedURL as URL in enumerator {
            let fileURL = enumeratedURL.standardizedFileURL
            let values = try fileURL.resourceValues(forKeys: keys)
            if values.isDirectory == true { directoryPaths.append(fileURL.path) }
            guard values.isRegularFile == true, values.isHidden != true else { continue }
            visitedFileCount += 1
            report(ScanProgress(completed: visitedFileCount, filename: fileURL.lastPathComponent))

            let fileExtension = fileURL.pathExtension.lowercased()
            guard modelExtensions.contains(fileExtension)
                    || companionExtensions.contains(fileExtension) else { continue }

            let file = ScannedFile(
                path: fileURL.path,
                filename: fileURL.lastPathComponent,
                fileExtension: fileExtension,
                size: Int64(values.fileSize ?? 0),
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate
            )
            filesByDirectory[fileURL.deletingLastPathComponent().path, default: []].append(file)
        }

        }
        if let scanError { throw scanError }
        report(ScanProgress(completed: visitedFileCount), force: true)
        let totalModels = filesByDirectory.values.reduce(0) { count, files in
            count + Set(files.filter { modelExtensions.contains($0.fileExtension) }.map { normalizedStem($0.filename) }).count
        } + trackedProjects.filter { $0.directoryPath != rootURL.path && !$0.directoryPath.hasPrefix(rootURL.path + "/") }.count
        var completedModels = 0
        var parsedModelCount = 0
        var deferredGroups: Set<String> = []
        var deferredPaths: Set<String> = []
        report(ScanProgress(stage: .reading, total: totalModels), force: true)
        let previousByPath = Dictionary(trackedProjects.flatMap { project in project.files.map { ($0.path, project) } }, uniquingKeysWith: { first, _ in first })
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
                } else if stem.hasSuffix(".readme"), groups[String(stem.dropLast(7))] != nil {
                    groups[String(stem.dropLast(7)), default: []].append(companion)
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

                report(ScanProgress(stage: .reading, completed: completedModels, total: totalModels, filename: representative.filename))
                let readmes = sourceReadmes(directoryURL: URL(fileURLWithPath: directoryPath), rootURL: rootURL, files: files)
                let signature = sourceSignature(file: representative, readmes: readmes)
                let previous = previousByPath[representative.path]
                let embeddedSource: String
                let sourceIdentity: String
                if !forceSources, previous?.sourceSignature == signature, let cached = previous?.embeddedSourceURL {
                    embeddedSource = cached
                    sourceIdentity = previous?.sourceIdentity ?? ""
                } else {
                    if representative.fileExtension == "3mf" { parsedModelCount += 1 }
                    let metadata: ExtractedModelMetadata?
                    do {
                        metadata = representative.fileExtension == "3mf"
                            ? try ThreeMFMetadataService.extract(fileURL: URL(fileURLWithPath: representative.path)) : nil
                    } catch {
                        if deferUnreadableModels {
                            deferredGroups.insert(groupKey)
                            deferredPaths.insert(representative.path)
                            continue
                        }
                        metadata = nil
                    }
                    let source = ModelSourceResolver.resolve(fileURL: URL(fileURLWithPath: representative.path), metadata: metadata, readmeURLs: readmes)
                    embeddedSource = source.modelURL ?? ""
                    sourceIdentity = source.identity ?? ""
                }
                projects.append(ScannedProject(
                    groupKey: groupKey,
                    name: URL(fileURLWithPath: representative.filename)
                        .deletingPathExtension().lastPathComponent,
                    directoryPath: directoryPath,
                    createdAt: createdAt,
                    modifiedAt: modifiedAt,
                    size: files.reduce(0) { $0 + $1.size },
                    files: sortedFiles,
                    embeddedSourceURL: embeddedSource,
                    sourceSignature: signature,
                    sourceIdentity: sourceIdentity
                ))
                completedModels += 1
            }
        }

        // Files explicitly moved or copied outside the library remain tracked at their new locations.
        for project in trackedProjects where scopePaths == nil && project.directoryPath != rootPath && !project.directoryPath.hasPrefix(rootPath + "/") {
            report(ScanProgress(stage: .reading, completed: completedModels, total: totalModels, filename: project.name))
            completedModels += 1
            let files = project.files.compactMap { file -> ScannedFile? in
                guard let values = try? file.url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                return ScannedFile(path: file.path, filename: file.filename, fileExtension: file.fileExtension, size: Int64(values.fileSize ?? 0), createdAt: values.creationDate, modifiedAt: values.contentModificationDate)
            }
            guard let representative = files.sorted(by: fileSort).first(where: { modelExtensions.contains($0.fileExtension) }) else { continue }
            let groupKey = project.directoryPath.lowercased() + "::" + project.name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
            let readmes = sourceReadmes(directoryURL: project.directoryURL, rootURL: rootURL, files: files)
            let signature = sourceSignature(file: representative, readmes: readmes)
            var source = ModelSourceInfo(modelURL: project.embeddedSourceURL, identity: project.sourceIdentity)
            if forceSources || signature != project.sourceSignature {
                let metadata: ExtractedModelMetadata?
                do {
                    if representative.fileExtension == "3mf" { parsedModelCount += 1 }
                    metadata = representative.fileExtension == "3mf" ? try ThreeMFMetadataService.extract(fileURL: URL(fileURLWithPath: representative.path)) : nil
                } catch {
                    if deferUnreadableModels {
                        deferredGroups.insert(groupKey)
                        deferredPaths.insert(representative.path)
                        continue
                    }
                    metadata = nil
                }
                source = ModelSourceResolver.resolve(fileURL: URL(fileURLWithPath: representative.path), metadata: metadata, readmeURLs: readmes)
            }
            projects.append(ScannedProject(groupKey: groupKey, name: project.name, directoryPath: project.directoryPath, createdAt: files.compactMap(\.createdAt).min(), modifiedAt: files.compactMap(\.modifiedAt).max(), size: files.reduce(0) { $0 + $1.size }, files: files, embeddedSourceURL: source.modelURL ?? "", sourceSignature: signature, sourceIdentity: source.identity ?? ""))
        }

        report(ScanProgress(stage: .reading, completed: completedModels, total: totalModels), force: true)
        return ScanResult(
            projects: projects.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            visitedFileCount: visitedFileCount,
            duration: Date().timeIntervalSince(startedAt),
            directoryPaths: directoryPaths,
            scopePaths: scopePaths,
            parsedModelCount: parsedModelCount,
            deferredGroups: deferredGroups,
            deferredPaths: deferredPaths
        )
    }

    private static func sourceSignature(file: ScannedFile, readmes: [URL]) -> String {
        var text = "v2|\(file.path)|\(file.size)|\(file.modifiedAt?.timeIntervalSince1970 ?? 0)"
        for url in readmes.sorted(by: { $0.path < $1.path }) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            text += "|\(url.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        // A digest detects changed browser provenance without persisting temporary signed URLs.
        text += ModelSourceResolver.whereFroms(URL(fileURLWithPath: file.path)).joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sourceReadmes(directoryURL: URL, rootURL: URL, files: [ScannedFile]) -> [URL] {
        var result = files.filter { ["md", "txt"].contains($0.fileExtension) }.map { URL(fileURLWithPath: $0.path) }
        // Export packages commonly keep README beside a files/ directory. Do not inherit a library-wide README.
        let parent = directoryURL.deletingLastPathComponent()
        if directoryURL.lastPathComponent.lowercased() == "files", parent.path != rootURL.path,
           parent.path.hasPrefix(rootURL.path + "/") {
            let children = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            result += children.filter { isReadme($0.lastPathComponent) && ["txt", "md"].contains($0.pathExtension.lowercased()) }
        }
        return result
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
