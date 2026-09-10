#if DEBUG
import AppKit
import Foundation

@MainActor
enum RoundTwoValidation {
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lokrel-round-two-\(UUID())").resolvingSymlinksInPath()
        let libraryRoot = root.appendingPathComponent("Library")
        let nested = libraryRoot.appendingPathComponent("Nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let preferenceKeys = ["showAllModels", "welcomeDismissed", "recentDestinations"]
        let savedPreferences = preferenceKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(preferenceKeys, savedPreferences) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "showAllModels")
        defaults.set(false, forKey: "welcomeDismissed")
        let dbPath = root.appendingPathComponent("test.sqlite").path
        let welcome = AppModel(databasePath: dbPath, scanOnLaunch: false)
        try check(welcome.isShowingWelcome, "A fresh install must show the welcome chooser")
        welcome.dismissWelcome()
        try check(!AppModel(databasePath: dbPath, scanOnLaunch: false).isShowingWelcome, "Choose Later must not prompt repeatedly")

        try UpgradeValidation.makeModel(nested.appendingPathComponent("Mixed.3mf"), modelID: "12345")
        try Data("solid test\nendsolid test".utf8).write(to: nested.appendingPathComponent("Mixed.stl"))
        try UpgradeValidation.makeModel(libraryRoot.appendingPathComponent("Single.3mf"), modelID: "12345")
        let recorder = ProgressRecorder()
        let scan = try LibraryScanner.scanSynchronously(rootURL: libraryRoot, progress: { recorder.add($0) })
        try check(recorder.values.first?.stage == .discovering, "Scan must report file discovery")
        try check(recorder.values.last?.stage == .reading && recorder.values.last?.completed == 2 && recorder.values.last?.total == 2, "Model scan progress must reach the actual total")
        let db = try DatabaseStore(path: dbPath)
        let first = try db.applyScan(scan, rootURL: libraryRoot, progress: { recorder.add($0) })
        try check(recorder.values.contains { $0.stage == .saving }, "Database indexing must report its progress")
        let second = try db.applyScan(LibraryScanner.scanSynchronously(rootURL: nested), rootURL: nested)
        try check(try db.projects(libraryID: first.id).count == 2 && db.projects(libraryID: second.id).count == 1, "Overlapping libraries must each index shared files")
        let original = try db.projects(libraryID: first.id).first { $0.name == "Mixed" }!
        try db.setNote("Keep this note", projectID: original.id)
        try db.createTag("Round Two")
        try db.setTag("Round Two", assigned: true, projectIDs: [original.id])
        let before = try original.files.map { try ProjectTransferService.digest($0.url) }
        try db.removeLibrary(id: first.id)
        try check(try db.libraries().map(\.id) == [second.id], "Remove must hide only the chosen library")
        try check(try original.files.map { try ProjectTransferService.digest($0.url) } == before, "Removing a library must leave files unchanged")
        _ = try db.restoreLibrary(rootURL: libraryRoot)
        let restored = try db.projects(libraryID: first.id).first { $0.id == original.id }!
        try check(restored.note == "Keep this note" && restored.tags.contains("Round Two"), "Re-adding the same directory must restore metadata")

        let app = AppModel(databasePath: dbPath, scanOnLaunch: false)
        app.openLibrary(nested)
        try check(app.library?.id == second.id && !app.isScanning && app.projects.count == 1, "Library switch must load the saved index without scanning")
        app.openLibrary(libraryRoot)
        try check(app.library?.id == first.id && app.projects.count == 2, "Switching back must restore the correct projects")
        defer { defaults.removeObject(forKey: "organizationSeen:" + libraryRoot.path) }
        app.finishScanPresentation()
        app.dismissOrganizationPrompt()
        app.finishScanPresentation()
        try check(!app.showOrganizationPrompt, "Closing library management must not repeat a declined organization prompt")
        app.showAllModels = false
        try check(app.browserItems.count == 1, "Same source group starts collapsed")
        app.showAllModels = true
        try check(app.browserItems.count == 2, "Show All must reveal every grouped project")
        app.filterFileTypes = ["stl"]
        try check(app.browserItems.count == 1, "Show All must still respect filters")
        app.clearFilters()
        app.showAllModels = false
        try check(app.browserItems.count == 1, "Turning Show All off must restore group collapse")
        app.showAllModels = true

        let single = app.projects.first { $0.name == "Single" }!
        let mixed = app.projects.first { $0.name == "Mixed" }!
        let singleDrag = ModelDragContent(projects: [single])
        try check(singleDrag.files == [single.primaryFile!.url] && !singleDrag.requiresFileChoice, "Single model must drag its actual file")
        try check(singleDrag.pasteboardItems()[0].string(forType: .fileURL) == single.primaryFile!.url.absoluteString, "External drag must advertise a real file URL")
        let mixedDrag = ModelDragContent(projects: [single, mixed])
        try check(mixedDrag.requiresFileChoice && mixedDrag.files.isEmpty && mixedDrag.pasteboardItems()[0].string(forType: .fileURL) == nil, "Ambiguous selection must not silently export a default format or a partial selection")
        try check(mixedDrag.pasteboardItems()[0].string(forType: .string)?.contains(mixed.id) == true, "Mixed projects must still support internal tag drags")
        app.selectProject(mixed.id, extending: false)
        _ = app.prepareDrag(mixed.id)
        try check(app.dragHint != nil && app.expandedProjectFiles.contains(mixed.id), "Ambiguous drag must explain and reveal the file choices")
        let stl = mixed.files.first { $0.fileExtension == "stl" }!
        let key = ModelDragContent.fileKey(projectID: mixed.id, fileID: stl.id)
        try check(app.prepareDrag(key)?.files == [stl.url], "Expanded STL row must export exactly the selected STL")
        app.selectModelFile(projectID: mixed.id, fileID: stl.id)
        app.togglePreview()
        try check(app.previewFileID == stl.id && app.previewProjectID == mixed.id, "Preview must honor an explicitly selected STL in a mixed project")
        app.navigatePreview(1)
        try check(app.previewFileID == nil, "Navigating to another project must clear the previous file choice")

        for index in 0..<7 { app.rememberDestination(root.appendingPathComponent("Target \(index)")) }
        try check(app.recentDestinations.count == 5 && app.recentDestinations.first?.hasSuffix("Target 6") == true, "Recent destinations must retain the five most recent successful folders")
        app.rememberDestination(root.appendingPathComponent("Target 4"))
        try check(app.recentDestinations.count == 5 && app.recentDestinations.first?.hasSuffix("Target 4") == true, "Reusing a destination must move it to the top without duplicates")
        app.removeLibrary(first)
        try check(app.library?.id == second.id, "Removing the active library must select another saved library")
        app.removeLibrary(second)
        try check(app.library == nil && app.projects.isEmpty && app.libraries.isEmpty, "Removing the last library must leave an empty browser")
        print("Round two validation passed: scan progress, onboarding, overlapping libraries, remove/restore metadata, instant switching, show-all filtering, explicit file drags, preview selection, recent destinations")
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "RoundTwoValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ScanProgress] = []
        var values: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return storage }
        func add(_ progress: ScanProgress) { lock.lock(); defer { lock.unlock() }; storage.append(progress) }
    }
}
#endif
