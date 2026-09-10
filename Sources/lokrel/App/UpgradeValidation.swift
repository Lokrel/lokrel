#if DEBUG
import Foundation
import ZIPFoundation

@MainActor
enum UpgradeValidation {
    static func run() throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("lokrelUpgrade-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = workspace.appendingPathComponent("Library")
        let target = root.appendingPathComponent("Organized")
        let external = workspace.appendingPathComponent("External")
        for url in [root, target, external] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: workspace) }
        for (directory, name, modelID) in [("A", "Holder", "614749"), ("B", "Holder", "614749"), ("C", "Other", "999999")] {
            let folder = root.appendingPathComponent(directory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try makeModel(folder.appendingPathComponent(name + ".3mf"), modelID: modelID)
            try Data("image-\(directory)".utf8).write(to: folder.appendingPathComponent(name + ".jpg"))
            try Data("readme-\(directory)".utf8).write(to: folder.appendingPathComponent("README.md"))
        }
        try Data("additional description".utf8).write(to: root.appendingPathComponent("A/Holder.md"))
        try Data("stl data".utf8).write(to: root.appendingPathComponent("C/Other.stl"))
        let db = try DatabaseStore(path: workspace.appendingPathComponent("test.sqlite").path)
        let scan = try LibraryScanner.scanSynchronously(rootURL: root)
        let library = try db.applyScan(scan, rootURL: root)
        var projects = try db.projects(libraryID: library.id)
        try check(projects.count == 3, "Scan should create three independent projects, got \(projects.map { $0.directoryPath + "/" + $0.name })")
        let groups = SourceGrouping.groups(projects)
        try check(groups.count == 1 && groups[0].projects.count == 2 && groups[0].isScattered, "Same embedded source must group across folders")
        try check(SourceGrouping.key("https://makerworld.com/zh/models/614749-holder?profile=3#x") == SourceGrouping.key("https://makerworld.com/en/models/614749?from=share"), "MakerWorld locale, slug and profile must normalize")
        try check(SourceGrouping.key("https://makerworld.com/en/models/614749") != SourceGrouping.key("https://makerworld.com/en/models/999999"), "Different MakerWorld projects must not merge")
        try check(SourceGrouping.key("") == nil && SourceGrouping.key("https://makerworld.com/") == nil, "Missing or homepage links must not group")
        try check(SourceGrouping.key("https://other.example/item?id=1") != SourceGrouping.key("https://other.example/item?id=2"), "Other sites must retain identity query parameters")
        try check(scan.directoryPaths.contains(target.path), "Empty folders must remain browsable")
        let original = groups[0].projects.first { $0.directoryURL.lastPathComponent == "A" }!
        let id = original.id
        try db.setFavorite(true, projectID: id)
        try db.setNote("keep note", projectID: id)
        try db.createTag("Acceptance")
        try db.setTag("Acceptance", assigned: true, projectIDs: [id])
        try db.setCoverOverride(path: original.files.first { $0.fileExtension == "jpg" }!.path, projectID: id)
        try db.setEditableDetails(EditableModelDetails(customName: "Custom Holder", author: "Author", sourceURL: "https://makerworld.com/en/models/614749", license: "Test", modelDescription: "Description"), projectID: id)
        projects = try db.projects(libraryID: library.id)
        let updatedGroups = SourceGrouping.groups(projects)
        let request = TransferRequest(projects: updatedGroups.flatMap(\.projects), groups: updatedGroups, copy: false)
        let plans = try ProjectTransferService.plan(request: request, parent: target, selectedGroups: Set(updatedGroups.map(\.id)))
        try check(plans.count == 2 && plans[0].directory == plans[1].directory, "Organization must bring both projects into one folder")
        try check(Set(plans.flatMap { $0.files.map { $0.destination.path } }).count == 7, "Repeated names must get unique planned destinations")
        let hashes = try Dictionary(uniqueKeysWithValues: plans.flatMap(\.files).map { ($0.source.path, try ProjectTransferService.digest($0.source)) })
        let report = ProjectTransferService.execute(plans, copy: false, parent: target) { try db.recordTransfer($0, copy: false, root: root) }
        try check(report.text.contains("2 succeeded, 0 failed"), "Organization should succeed: \(report.text)")
        for file in plans.flatMap(\.files) {
            try check(!fm.fileExists(atPath: file.source.path), "Moved original should no longer occupy its old path")
            try check(try ProjectTransferService.digest(file.destination) == hashes[file.source.path], "Moved content changed")
        }
        _ = try db.applyScan(LibraryScanner.scanSynchronously(rootURL: root), rootURL: root)
        projects = try db.projects(libraryID: library.id)
        guard let moved = projects.first(where: { $0.id == id }) else { throw Failure("Project identity lost after move and scan") }
        try check(moved.favorite && moved.note == "keep note" && moved.tags == ["Acceptance"] && moved.displayName == "Custom Holder" && moved.author == "Author" && moved.license == "Test" && moved.modelDescription == "Description", "Project edits were lost after move")
        try check(moved.files.count == original.files.count && moved.files.contains(where: { $0.path == moved.coverOverridePath }), "Companion association or cover path lost after rescan")
        try check(SourceGrouping.groups(projects).count == 1 && !SourceGrouping.groups(projects)[0].isScattered, "Organized group should remain virtual but not prompt again")
        let copyRequest = TransferRequest(projects: [moved], groups: [], copy: true)
        let copies = try ProjectTransferService.plan(request: copyRequest, parent: external, selectedGroups: [])
        let copyReport = ProjectTransferService.execute(copies, copy: true, parent: external) { try db.recordTransfer($0, copy: true, root: root) }
        try check(copyReport.text.contains("1 succeeded, 0 failed"), "External copy failed")
        for file in copies.flatMap(\.files) {
            try check(try ProjectTransferService.digest(file.source) == ProjectTransferService.digest(file.destination), "Copy must preserve both contents")
        }
        let tracked = try db.projects(libraryID: library.id)
        let secondRoot = workspace.appendingPathComponent("Second Library")
        try fm.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        _ = try db.applyScan(LibraryScanner.scanSynchronously(rootURL: secondRoot), rootURL: secondRoot)
        let restored = try db.projects(rootURL: root)
        try check(Set(restored.map(\.id)) == Set(tracked.map(\.id)), "Returning to a library must restore its tracked external projects")
        _ = try db.applyScan(LibraryScanner.scanSynchronously(rootURL: root, trackedProjects: restored), rootURL: root)
        let afterExternal = try db.projects(libraryID: library.id)
        try check(afterExternal.count == 4 && afterExternal.contains(where: { $0.directoryPath == external.path && $0.favorite && $0.tags == ["Acceptance"] }), "External copy and metadata must survive rescan")
        // A file appearing after plan review must be preserved and reported, never overwritten.
        let raceFolder = root.appendingPathComponent("Race")
        try fm.createDirectory(at: raceFolder, withIntermediateDirectories: true)
        let race = try ProjectTransferService.plan(request: copyRequest, parent: raceFolder, selectedGroups: [])
        let collision = race[0].files[0].destination
        try Data("existing file".utf8).write(to: collision)
        let raceReport = ProjectTransferService.execute(race, copy: true, parent: raceFolder) { _ in throw Failure("Must not commit") }
        try check(try Data(contentsOf: collision) == Data("existing file".utf8), "Collision overwrote an existing file")
        try check(raceReport.text.contains("0 succeeded, 1 failed"), "Collision must be reported")
        // Simulate a database write failure after moving files; all files must return to the source.
        let rollbackFolder = root.appendingPathComponent("Rollback")
        try fm.createDirectory(at: rollbackFolder, withIntermediateDirectories: true)
        let rollback = try ProjectTransferService.plan(request: TransferRequest(projects: [moved], groups: [], copy: false), parent: rollbackFolder, selectedGroups: [])
        let rollbackReport = ProjectTransferService.execute(rollback, copy: false, parent: rollbackFolder) { _ in throw Failure("Injected database failure") }
        try check(rollbackReport.text.contains("0 succeeded, 1 failed"), "Rollback failure must be reported")
        for file in rollback.flatMap(\.files) {
            try check(fm.fileExists(atPath: file.source.path) && !fm.fileExists(atPath: file.destination.path), "Failed move did not roll back")
        }
        try check(BrowserNavigation.destination(current: 2, count: 10, columns: 3, key: 125) == 5, "Down must follow grid columns")
        try check(BrowserNavigation.destination(current: 2, count: 10, columns: 4, key: 125) == 6, "Down must adapt to resized grid")
        try check(BrowserNavigation.destination(current: 0, count: 10, columns: 3, key: 123) == 0, "Left at first item must remain in bounds")
        try check(BrowserNavigation.destination(current: 9, count: 10, columns: 3, key: 124) == 9, "Right at last item must remain in bounds")
        try check(BrowserNavigation.destination(current: 2, count: 10, columns: 3, key: 126) == 2, "Up in the first row must keep the same column")
        try check(BrowserNavigation.destination(current: 9, count: 11, columns: 3, key: 125) == 9, "Down in the last row must keep the same item")
        try check(BrowserNavigation.destination(current: nil, count: 0, columns: 3, key: 124) == nil, "Empty grid must not select")
        let app = AppModel(databasePath: workspace.appendingPathComponent("test.sqlite").path)
        let total = app.projects.count
        try check(app.availableFileTypes == ["3mf", "stl"], "File type filters must come from scanned model formats")
        try check(app.browserItems.count < total, "Source groups must start collapsed")
        for group in app.sourceGroups { app.toggleGroup(group.id) }
        try check(app.browserItems.count == total, "Expanded groups must expose all individual projects")
        let first = app.browserItems[0].id
        app.selectProject(first, extending: false)
        app.navigate(key: 124, columns: 3, extending: true)
        try check(app.selectedProjectIDs.count == 2, "Shift navigation must select a range")
        app.selectProject(first, extending: false)
        app.togglePreview()
        app.navigatePreview(1)
        try check(app.previewProjectID == app.browserItems[1].id && app.selectedProjectIDs == [app.browserItems[1].id], "Preview and grid selection must stay synchronized")
        app.togglePreview()
        app.filterFileTypes = ["stl"]
        try check(app.filteredProjects.count == 1 && app.filteredProjects[0].modelTypes == "3MF · STL", "Type filter must match an associated format, not only the primary file")
        app.filterFileTypes = ["3mf", "stl"]
        try check(app.filteredProjects.count == total, "Multiple file types must match either type")
        app.searchText = "Custom Holder"
        try check(app.filteredProjects.count == 2, "Search must combine with type filtering")
        app.clearFilters()
        app.searchText = "no match"
        try check(app.filteredProjects.isEmpty && app.selectedProjectIDs.isEmpty, "Empty results must clear selection")
        let recoveryFolder = root.appendingPathComponent("Recovery")
        try fm.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        let recoverPlans = try ProjectTransferService.plan(request: TransferRequest(projects: [moved], groups: [], copy: false), parent: recoveryFolder, selectedGroups: [])
        let primaryMove = recoverPlans[0].files.first { $0.source.path == moved.primaryFile?.path }!
        let primaryHash = try ProjectTransferService.digest(primaryMove.source)
        let recoveryReport = ProjectTransferService.execute(recoverPlans, copy: false, parent: recoveryFolder, recover: { actual in
            try db.recordTransfer(actual, copy: false, root: root)
        }) { _ in
            try Data("new unrelated file".utf8).write(to: primaryMove.source)
            throw Failure("Injected failure with a concurrent source conflict")
        }
        try check(recoveryReport.text.contains("ROLLBACK FAILED") && recoveryReport.text.contains("Library reconciled"), "Incomplete rollback must report and reconcile actual locations")
        try check(try ProjectTransferService.digest(primaryMove.destination) == primaryHash, "A rollback conflict must retain the original model at destination")
        try check(try Data(contentsOf: primaryMove.source) == Data("new unrelated file".utf8), "Rollback must not overwrite a concurrent source file")
        let recovered = try db.projects(libraryID: library.id).first { $0.id == moved.id }!
        try check(recovered.primaryFile?.path == primaryMove.destination.path && recovered.files.allSatisfy { fm.fileExists(atPath: $0.path) }, "Recovery must index the actual remaining paths")
        print("Upgrade validation passed: source grouping, collision planning, verified moves/copies, metadata persistence, external tracking, rollback, keyboard boundaries")
    }

    static func makeModel(_ url: URL, modelID: String) throws {
        let archive = try Archive(url: url, accessMode: .create)
        let xml = "<model xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><metadata name=\"DesignModelId\">\(modelID)</metadata><resources/><build/></model>"
        let data = Data(xml.utf8)
        try archive.addEntry(with: "3D/3dmodel.model", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
        }
    }
    private static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }
}
#endif
