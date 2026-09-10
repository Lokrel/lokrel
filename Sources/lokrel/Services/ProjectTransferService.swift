import Foundation
import CryptoKit

struct TransferRequest: Identifiable {
    let id = UUID()
    let projects: [ModelProject]
    let groups: [SourceGroup]
    let copy: Bool
    var destination: URL? = nil
    var isOrganization: Bool { !groups.isEmpty }
}

struct FileTransfer: Identifiable, Sendable {
    let source: URL
    let destination: URL
    var id: String { source.path }
}

struct ProjectTransfer: Identifiable, Sendable {
    let project: ModelProject
    let directory: URL
    let files: [FileTransfer]
    let groupID: String?
    var groupName: String? = nil
    var id: String { project.id }
}

struct TransferReport: Identifiable {
    let id = UUID()
    let destination: URL
    let text: String
    var succeeded: Int = 0
}

struct TransferFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ProjectTransferService {
    static func folderName(_ name: String) -> String {
        let result = name.components(separatedBy: CharacterSet(charactersIn: "/:\n\r\0"))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." ? "Models" : String(result.prefix(100))
    }

    static func plan(request: TransferRequest, parent: URL, selectedGroups: Set<String>) throws -> [ProjectTransfer] {
        let fm = FileManager.default
        let parent = parent.resolvingSymlinksInPath().standardizedFileURL
        var reservedStems: [String: Set<String>] = [:]
        var reservedPaths: Set<String> = []
        var result: [ProjectTransfer] = []
        let groupByProject = Dictionary(uniqueKeysWithValues: request.groups.flatMap { group in
            group.projects.map { ($0.id, group) }
        })
        for project in request.projects {
            let group = groupByProject[project.id]
            if let group, !selectedGroups.contains(group.id) { continue }
            let groupName = group.map { folderName($0.name) + " - " + String($0.fingerprint.prefix(8)) }
            let directory = groupName.map { parent.appendingPathComponent($0, isDirectory: true) } ?? parent
            if !request.copy && project.directoryURL.resolvingSymlinksInPath().standardizedFileURL == directory { continue }
            if reservedStems[directory.path] == nil {
                let names = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                reservedStems[directory.path] = Set(names.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
            }
            let base = folderName(project.name)
            var suffix = 1
            var stem = base
            var files: [FileTransfer] = []
            while true {
                // Every companion shares the model stem, including README, so a rescan keeps it attached.
                files = project.files.map { file in
                    let sameType = project.files.filter { $0.fileExtension.lowercased() == file.fileExtension.lowercased() }
                    let originalStem = file.url.deletingPathExtension().lastPathComponent.lowercased()
                    let isReadme = originalStem == "readme" || originalStem.hasSuffix(".readme")
                    let attachment = isReadme && sameType.count > 1 ? ".readme" : ""
                    return FileTransfer(source: file.url, destination: directory.appendingPathComponent(stem + attachment + "." + file.fileExtension))
                }
                let paths = files.map { $0.destination.path.lowercased() }
                guard Set(paths).count == paths.count else {
                    throw TransferFailure(message: L10n.format("%@ has multiple companion files of the same type. Resolve these names before transferring.", project.displayName))
                }
                if reservedStems[directory.path]?.contains(stem.lowercased()) != true &&
                    !files.contains(where: { fm.fileExists(atPath: $0.destination.path) || reservedPaths.contains($0.destination.path.lowercased()) }) { break }
                suffix += 1
                stem = "\(base) (\(suffix))"
            }
            reservedStems[directory.path, default: []].insert(stem.lowercased())
            reservedPaths.formUnion(files.map { $0.destination.path.lowercased() })
            result.append(ProjectTransfer(project: project, directory: directory, files: files, groupID: group?.id, groupName: group?.name))
        }
        return result
    }

    static func preflight(_ plans: [ProjectTransfer], parent: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isWritableFile(atPath: parent.path) else {
            throw TransferFailure(message: L10n.text("The destination folder is not writable."))
        }
        let required = plans.reduce(Int64(0)) { $0 + $1.project.size }
        if let values = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage, available < required {
            throw TransferFailure(message: L10n.format("The destination needs at least %@ of free space.", ByteCountFormatter.string(fromByteCount: required, countStyle: .file)))
        }
        for plan in plans {
            if fm.fileExists(atPath: plan.directory.path) && !fm.isWritableFile(atPath: plan.directory.path) {
                throw TransferFailure(message: L10n.format("The destination is not writable: %@", plan.directory.path))
            }
            for file in plan.files {
                guard fm.isReadableFile(atPath: file.source.path) else {
                    throw TransferFailure(message: L10n.format("Cannot read %@", file.source.path))
                }
                guard !fm.fileExists(atPath: file.destination.path) else {
                    throw TransferFailure(message: L10n.format("A destination now exists. Review the plan again: %@", file.destination.path))
                }
            }
        }
    }

    static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize()
    }

    // Each project is committed independently. A failed project rolls back before the next one starts.
    static func execute(_ plans: [ProjectTransfer], copy: Bool, parent: URL,
                        skipped: [ModelProject] = [], recover: (ProjectTransfer) throws -> Void = { _ in }, commit: (ProjectTransfer) throws -> Void) -> TransferReport {
        let fm = FileManager.default
        var lines = [L10n.text(copy ? "lokrel Copy Report" : "lokrel Move Report"), Date().formatted(), L10n.format("Destination: %@", parent.path), ""]
        if !skipped.isEmpty {
            lines += skipped.map { L10n.format("SKIPPED: %@ — unselected or already at destination (%@)", $0.displayName, $0.directoryPath) }
            lines.append("")
        }
        var succeeded = 0
        var failed = 0
        var groupResults: [String: [Bool]] = [:]
        for plan in plans {
            var completed: [FileTransfer] = []
            do {
                try preflight([plan], parent: parent)
                try fm.createDirectory(at: plan.directory, withIntermediateDirectories: true)
                for file in plan.files {
                    let expected = try digest(file.source)
                    if copy { try fm.copyItem(at: file.source, to: file.destination) }
                    else { try fm.moveItem(at: file.source, to: file.destination) }
                    completed.append(file)
                    guard try digest(file.destination) == expected else {
                        throw TransferFailure(message: L10n.format("Content verification failed: %@", file.destination.path))
                    }
                }
                try commit(plan)
                succeeded += 1
                if let groupID = plan.groupID { groupResults[groupID, default: []].append(true) }
                lines.append(L10n.format("SUCCESS: %@ (%@)", plan.project.displayName, L10n.format("%ld files", plan.files.count)))
                lines += plan.files.map { "  \($0.source.path) → \($0.destination.path)" }
            } catch {
                failed += 1
                if let groupID = plan.groupID { groupResults[groupID, default: []].append(false) }
                lines.append(L10n.format("FAILED: %@: %@", plan.project.displayName, error.localizedDescription))
                for file in completed.reversed() {
                    do {
                        if copy { try fm.removeItem(at: file.destination) }
                        else { try fm.moveItem(at: file.destination, to: file.source) }
                    } catch { lines.append(L10n.format("  ROLLBACK FAILED: %@", error.localizedDescription)) }
                }
                if !copy {
                    let remaining = completed.filter { fm.fileExists(atPath: $0.destination.path) }
                    if !remaining.isEmpty {
                        let remainingIDs = Set(remaining.map(\.id))
                        let actualFiles = plan.files.map { file in
                            FileTransfer(source: file.source, destination: remainingIDs.contains(file.id) ? file.destination : file.source)
                        }
                        let primary = actualFiles.first { $0.source.path == plan.project.primaryFile?.path } ?? actualFiles[0]
                        let actualPlan = ProjectTransfer(project: plan.project, directory: primary.destination.deletingLastPathComponent(), files: actualFiles, groupID: plan.groupID, groupName: plan.groupName)
                        do {
                            try recover(actualPlan)
                            lines.append("  Library reconciled with the files remaining at their actual locations.")
                        } catch { lines.append(L10n.format("  Library recovery failed: %@", error.localizedDescription)) }
                    }
                }
                for file in plan.files {
                    lines.append(L10n.format("  Source %@: %@", L10n.text(fm.fileExists(atPath: file.source.path) ? "present" : "absent"), file.source.path))
                    lines.append(L10n.format("  Destination %@: %@", L10n.text(fm.fileExists(atPath: file.destination.path) ? "present" : "absent"), file.destination.path))
                }
            }
            lines.append("")
        }
        let summaries = groupResults.keys.sorted().map { id in
            let statuses = groupResults[id] ?? []
            let name = plans.first(where: { $0.groupID == id })?.groupName ?? id
            return L10n.format("Group %@: %ld succeeded, %ld failed", name, statuses.filter { $0 }.count, statuses.filter { !$0 }.count)
        }
        lines.insert(contentsOf: summaries, at: 3)
        lines.insert(L10n.format("Projects: %ld succeeded, %ld failed, %ld skipped", succeeded, failed, skipped.count), at: 3)
        return TransferReport(destination: parent, text: lines.joined(separator: "\n"), succeeded: succeeded)
    }
}
