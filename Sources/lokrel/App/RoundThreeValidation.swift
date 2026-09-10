#if DEBUG
import Foundation

@MainActor
enum RoundThreeValidation {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    static func run() throws {
        try check(makerWorldModelURL(from: "CN8c2b9994d6c83b") == nil, "Internal CN IDs must not become broken page URLs")
        try check(makerWorldModelURL(from: "random123stuff") == nil, "Never extract an arbitrary numeric substring")
        try check(SourceGrouping.key(ModelSourceResolver.internalIdentity("CN8c2b9994d6c83b")!) == "makerworld-cn-model:cn8c2b9994d6c83b", "CN provenance must group without inventing a URL")
        try check(ModelSourceResolver.modelPage("https://makerworld.com.cn/zh/models/2808662-adjustable-phone-stand?from=recommend") == "https://makerworld.com.cn/zh/models/2808662", "Public CN page must retain its region and numeric page ID")
        try check(ModelSourceResolver.modelPage("https://shop.bambulab.com/products/tool") == nil, "Shop links are not model pages")
        try check(ModelSourceResolver.modelPage("https://cults3d.com/en/3d-model/art/moon?utm_source=test") == "https://cults3d.com/en/3d-model/art/moon", "Cults model pages normalize")
        try check(SourceGrouping.key("https://cdn.example/model.3mf?Signature=secret") == nil, "Signed download URLs must not group")
        let ambiguous = ExtractedModelMetadata(entries: [MetadataEntry(name: "Description", value: "https://makerworld.com/en/models/123 https://makerworld.com/en/models/456")])
        try check(ambiguous.sourceURL == nil, "Ambiguous description links must not guess")

        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("lokrel-round-three-\(UUID())").resolvingSymlinksInPath()
        let root = workspace.appendingPathComponent("Library")
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        for url in [a, b] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: workspace) }
        try UpgradeValidation.makeModel(a.appendingPathComponent("Model2.3mf"), modelID: "CN8c2b9994d6c83b")
        try UpgradeValidation.makeModel(b.appendingPathComponent("Model10.3mf"), modelID: "12345")
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000), .modificationDate: Date(timeIntervalSince1970: 1_650_000_000)], ofItemAtPath: a.appendingPathComponent("Model2.3mf").path)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_620_000_000), .modificationDate: Date(timeIntervalSince1970: 1_630_000_000)], ofItemAtPath: b.appendingPathComponent("Model10.3mf").path)
        let db = try DatabaseStore(path: workspace.appendingPathComponent("index.sqlite").path)
        let first = try LibraryScanner.scanSynchronously(rootURL: root)
        let library = try db.applyScan(first, rootURL: root)
        let projects = try db.projects(libraryID: library.id)
        let original = projects.first { $0.name == "Model2" }!
        try db.setNote("Keep note", projectID: original.id)
        try db.setEditableDetails(EditableModelDetails(customName: "Custom", author: "", sourceURL: "https://example.com/my-model", license: "", modelDescription: ""), projectID: original.id)
        try db.setTag("Tools", assigned: true, projectIDs: [original.id])
        let second = try LibraryScanner.scanSynchronously(rootURL: root, trackedProjects: projects)
        try check(second.parsedModelCount == 0, "An unchanged library must not reparse models")
        _ = try db.applyScan(second, rootURL: root)
        let reloaded = try db.projects(libraryID: library.id)
        try check(Set(reloaded.flatMap(\.files).map(\.id)) == Set(projects.flatMap(\.files).map(\.id)), "Refresh must preserve file IDs")
        try check(reloaded.first { $0.id == original.id }?.sourceURL == "https://example.com/my-model", "Refresh must preserve custom source")
        try UpgradeValidation.makeModel(a.appendingPathComponent("New.3mf"), modelID: "67890")
        let partial = try LibraryScanner.scanSynchronously(rootURL: root, trackedProjects: reloaded, scopePaths: [a.path])
        try check(partial.parsedModelCount == 1 && partial.projects.count == 2, "A directory update must parse only the new model")
        _ = try db.applyScan(partial, rootURL: root)
        try check(try db.projects(libraryID: library.id).count == 3, "Partial scan must retain untouched directories")
        try fm.removeItem(at: a.appendingPathComponent("New.3mf"))
        _ = try db.applyScan(LibraryScanner.scanSynchronously(rootURL: root, trackedProjects: try db.projects(libraryID: library.id), scopePaths: [a.path]), rootURL: root)
        try check(try db.projects(libraryID: library.id).count == 2, "Partial deletion must remove only the missing project")
        let preserved = try db.projects(libraryID: library.id).first { $0.id == original.id }!
        try check(preserved.note == "Keep note" && preserved.tags == ["Tools"], "Incremental updates must preserve notes and tags")
        let named = BrowserSort.filename.sorted(reloaded, ascending: true, tagOrder: [])
        try check(named.map(\.name) == ["Model2", "Model10"], "Filename sorting must be natural and ignore custom display names")
        try check(BrowserSort.filename.sorted(reloaded, ascending: false, tagOrder: []).map(\.name) == ["Model10", "Model2"], "Descending names must reverse")
        try check(BrowserSort.tags.sorted(reloaded, ascending: false, tagOrder: ["Tools"]).first?.id == original.id, "Untagged models must remain last in both directions")
        let created = BrowserSort.created.sorted(reloaded, ascending: true, tagOrder: [])
        try check(created.first?.primaryFile?.createdAt == reloaded.compactMap { $0.primaryFile?.createdAt }.min(), "Creation sorting must use file creation dates")

        try check(BrowserSort.created.sorted(reloaded, ascending: false, tagOrder: []).first?.name == "Model10", "Creation descending must use filesystem dates instead of equal import dates")
        try check(BrowserSort.modified.sorted(reloaded, ascending: true, tagOrder: []).first?.name == "Model10", "Modification ascending must follow modification dates")
        try check(BrowserSort.modified.sorted(reloaded, ascending: false, tagOrder: []).first?.name == "Model2", "Modification descending must reverse")
        for ascending in [true, false] {
            let sizes = BrowserSort.size.sorted(reloaded, ascending: ascending, tagOrder: []).map(\.size)
            try check(sizes == sizes.sorted(by: ascending ? (<) : (>)), "Size sorting must honor direction")
        }
        _ = try db.applyScan(LibraryScanner.scanSynchronously(rootURL: b), rootURL: b)
        let app = AppModel(databasePath: workspace.appendingPathComponent("index.sqlite").path, scanOnLaunch: false)
        defer { for path in [root.path, b.path] { UserDefaults.standard.removeObject(forKey: "browserSort:" + path) } }
        app.openLibrary(root)
        app.sortOrder = .created
        app.sortAscending = false
        app.openLibrary(b)
        try check(app.sortOrder == .filename && app.sortAscending, "Each library must have its own sort defaults")
        app.openLibrary(root)
        try check(app.sortOrder == .created && !app.sortAscending, "Library switch must restore sorting")
        let relaunched = AppModel(databasePath: workspace.appendingPathComponent("index.sqlite").path, scanOnLaunch: false)
        try check(relaunched.sortOrder == .created && !relaunched.sortAscending, "Relaunch must restore sorting")
        app.sortOrder = .filename
        app.sortAscending = false
        app.selectProject(app.browserItems[0].id, extending: false)
        app.togglePreview()
        app.navigatePreview(1)
        try check(app.previewProjectID == app.browserItems[1].id, "Preview must follow sorted browser order")

        let package = root.appendingPathComponent("Export")
        let files = package.appendingPathComponent("files")
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("solid x\nendsolid x".utf8).write(to: files.appendingPathComponent("Skull.stl"))
        try Data("Skull https://www.thingiverse.com/thing:7403639\nSummary:\nReference https://www.thingiverse.com/thing:111".utf8).write(to: package.appendingPathComponent("README.txt"))
        let export = try LibraryScanner.scanSynchronously(rootURL: root, trackedProjects: reloaded, scopePaths: [package.path])
        try check(export.projects.first?.embeddedSourceURL == "https://www.thingiverse.com/thing:7403639", "Parent export README must identify its own project")
        // Previously transferred projects outside the root still need source migration and reparsing.
        try fm.removeItem(at: a.appendingPathComponent("Model2.3mf"))
        try UpgradeValidation.makeModel(a.appendingPathComponent("Model2.3mf"), modelID: "54321")
        let external = try LibraryScanner.scanSynchronously(rootURL: b, trackedProjects: reloaded)
        try check(external.projects.first { $0.directoryPath == a.path }?.embeddedSourceURL == "https://makerworld.com/en/models/54321", "Full scan must refresh a tracked external model source")
        let forced = try LibraryScanner.scanSynchronously(rootURL: b, trackedProjects: reloaded, forceSources: true)
        try check(forced.parsedModelCount == 2, "Full rescan must reparse sources inside and outside the root")
        print("Round three validation passed: source identity, cache, partial updates, file IDs, manual metadata, sorting, export README")
    }

    static func benchmark() throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("lokrel-incremental-benchmark-\(UUID())").resolvingSymlinksInPath()
        let root = workspace.appendingPathComponent("Library")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        let template = workspace.appendingPathComponent("Template.3mf")
        try UpgradeValidation.makeModel(template, modelID: "12345")
        let data = try Data(contentsOf: template)
        for folder in 0..<60 {
            let directory = root.appendingPathComponent("Folder\(folder)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<50 { try data.write(to: directory.appendingPathComponent("Model\(index).3mf")) }
        }
        let db = try DatabaseStore(path: workspace.appendingPathComponent("benchmark.sqlite").path)
        let started = Date()
        let first = try LibraryScanner.scanSynchronously(rootURL: root)
        let library = try db.applyScan(first, rootURL: root)
        let fullTime = Date().timeIntervalSince(started)
        let tracked = try db.projects(libraryID: library.id)
        let checkStarted = Date()
        let before = try LibraryInventory.read(root: root, scopes: nil)
        let inventoryTime = Date().timeIntervalSince(checkStarted)
        let cachedStarted = Date()
        let cached = try LibraryScanner.scanSynchronously(rootURL: root, trackedProjects: tracked)
        _ = try db.applyScan(cached, rootURL: root)
        let cachedTime = Date().timeIntervalSince(cachedStarted)
        try check(cached.parsedModelCount == 0, "Cached benchmark must parse zero models")
        let changedFolder = root.appendingPathComponent("Folder0")
        try data.write(to: changedFolder.appendingPathComponent("New.3mf"))
        let updateStarted = Date()
        let update = try LibraryScanner.scanSynchronously(rootURL: root, trackedProjects: tracked, scopePaths: [changedFolder.path])
        _ = try db.applyScan(update, rootURL: root)
        let updateTime = Date().timeIntervalSince(updateStarted)
        try check(update.parsedModelCount == 1 && update.projects.count == 51, "Single-folder benchmark must parse one new model")
        try check(try db.projects(libraryID: library.id).count == 3001 && before.count == 3060, "Benchmark must retain all 3000 models plus new file")
        print(String(format: "Incremental benchmark: 3000 models, full scan+index %.3fs; metadata inventory %.3fs; cached full scan+index %.3fs (0 parsed); one-folder update %.3fs (1 parsed, 51 projects visited)", fullTime, inventoryTime, cachedTime, updateTime))
    }

    static func samples(_ root: URL) throws {
        let scan = try LibraryScanner.scanSynchronously(rootURL: root)
        let expected: [String: String] = [
            "Adjustable_Phone_Stand_Gen2": "CN8c2b9994d6c83b", "Adjustable_Phone_Stand_Gen2_Tall": "CN8c2b9994d6c83b",
            "Space+capsule+pencil+case+D5x3": "CNa916994c841645", "零件1_1": "CNd59b2e785a9605", "喷气火箭1111": "CN1c772829780acd"
        ]
        for project in scan.projects {
            if let id = expected[project.name] { try check(project.embeddedSourceURL.isEmpty && project.sourceIdentity == ModelSourceResolver.internalIdentity(id), "Wrong real sample source identity: \(project.name)") }
            if project.directoryPath.contains("7403639") { try check(project.embeddedSourceURL == "https://www.thingiverse.com/thing:7403639", "Wrong Thingiverse sample source") }
            if ["homeyclicks_Mooncake", "镂空草绳编织球"].contains(project.name) { try check(project.embeddedSourceURL.isEmpty, "Do not fabricate model pages for download-only samples") }
            print("Sample identity: \(project.sourceIdentity)")
            print("Sample \(project.name): \(project.embeddedSourceURL.isEmpty ? "No stable model page" : project.embeddedSourceURL)")
        }
        print("Read-only sample validation passed: \(scan.projects.count) projects")
    }

    static func refresh() async throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("lokrel-refresh-\(UUID())").resolvingSymlinksInPath()
        let root = workspace.appendingPathComponent("Library")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        let db = try DatabaseStore(path: workspace.appendingPathComponent("index.sqlite").path)
        try UpgradeValidation.makeModel(root.appendingPathComponent("First.3mf"), modelID: "12345")
        let location = try db.applyScan(LibraryScanner.scanSynchronously(rootURL: root), rootURL: root)
        let initial = try db.projects(libraryID: location.id)[0]
        try db.setNote("Survives offline", projectID: initial.id)
        let app = AppModel(databasePath: workspace.appendingPathComponent("index.sqlite").path)
        try await wait { !app.isRefreshing }
        print("Refresh initial state: \(app.projects.count), \(app.refreshMessage)")
        app.selectProject(initial.id, extending: false)
        try UpgradeValidation.makeModel(root.appendingPathComponent("Second.3mf"), modelID: "67890")
        do { try await wait { app.projects.count == 2 } } catch { throw Failure(description: "Notification add timed out: \(app.projects.count), \(app.refreshMessage)") }
        try check(app.selectedProjectIDs == [initial.id], "Automatic update must preserve selection")
        try check(app.projects.first { $0.id == initial.id }?.files.map(\.id) == initial.files.map(\.id), "Automatic update must preserve file row identities")
        print("Refresh: actual filesystem notification detected new model")
        try fm.removeItem(at: root.appendingPathComponent("Second.3mf"))
        try await wait { app.projects.count == 1 }
        print("Refresh: actual filesystem notification detected removal")
        try await wait { !app.isRefreshing }
        let partial = root.appendingPathComponent("Partial.3mf")
        try Data("PK unfinished".utf8).write(to: partial)
        app.refreshLibrary()
        try await wait { !app.isRefreshing }
        try check(app.projects.count == 1 && app.refreshMessage.contains("unavailable"), "Incomplete archive must not become a model or remove existing projects")
        try fm.removeItem(at: partial)
        try UpgradeValidation.makeModel(partial, modelID: "34567")
        try await wait { app.projects.count == 2 }
        try fm.removeItem(at: partial)
        try await wait { app.projects.count == 1 }
        // Replacing an existing file must refresh its source without losing its project metadata.
        try fm.removeItem(at: root.appendingPathComponent("First.3mf"))
        try UpgradeValidation.makeModel(root.appendingPathComponent("First.3mf"), modelID: "54321")
        try await wait { app.projects.first?.embeddedSourceURL == "https://makerworld.com/en/models/54321" }
        try check(app.projects[0].id == initial.id && app.projects[0].note == "Survives offline", "Model replacement must retain user metadata")
        try await wait { !app.isRefreshing }
        let offline = workspace.appendingPathComponent("Disconnected")
        try fm.moveItem(at: root, to: offline)
        app.refreshLibrary()
        try await wait { !app.isRefreshing }
        try check(app.projects.count == 1 && app.projects[0].note == "Survives offline" && app.refreshMessage.contains("offline"), "Offline root must preserve its saved index")
        try fm.moveItem(at: offline, to: root)
        app.refreshLibrary()
        try await wait { !app.isRefreshing }
        try check(app.refreshMessage == "Up to date", "Reconnect must reconcile without losing metadata")
        app.disableNotificationsForValidation()
        app.selectedSection = .folder(root.path)
        try UpgradeValidation.makeModel(root.appendingPathComponent("Polling.3mf"), modelID: "87654")
        try await wait(attempts: 200) { app.projects.count == 2 }
        print("Refresh: periodic check detected new file with filesystem notifications disabled")
        print("Refresh validation passed: notification, incremental add/remove, incomplete archive deferral, model replacement, selection, offline preservation, reconnect")
    }

    static func nasRefresh(parent: URL) async throws {
        let fm = FileManager.default
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
        try check(values.isDirectory == true && values.volumeIsLocal == false, "NAS validation requires an existing network directory")
        let name = "Lokrel-Acceptance-\(UUID())"
        let workspace = parent.appendingPathComponent(name)
        let root = workspace.appendingPathComponent("Library")
        let local = fm.temporaryDirectory.appendingPathComponent(name)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace); try? fm.removeItem(at: local) }
        print("NAS isolated fixture: \(workspace.path)")
        let path = local.appendingPathComponent("index.sqlite").path
        let db = try DatabaseStore(path: path)
        try UpgradeValidation.makeModel(root.appendingPathComponent("First.3mf"), modelID: "12345")
        let library = try db.applyScan(LibraryScanner.scanSynchronously(rootURL: root), rootURL: root)
        let initial = try db.projects(libraryID: library.id)[0]
        try db.setNote("NAS note retained", projectID: initial.id)
        let app = AppModel(databasePath: path)
        try await wait { !app.isRefreshing }
        app.disableNotificationsForValidation()
        app.selectedSection = .folder(root.path)
        app.selectProject(initial.id, extending: false)
        let second = root.appendingPathComponent("Second.3mf")
        try UpgradeValidation.makeModel(second, modelID: "67890")
        try await wait(attempts: 225) { app.projects.count == 2 }
        try check(app.selectedProjectIDs == [initial.id], "NAS polling must preserve selection")
        try check(app.projects.first { $0.id == initial.id }?.files.map(\.id) == initial.files.map(\.id), "NAS polling must preserve unchanged file IDs")
        print("NAS PASS: 30-second folder polling detected addition, preserved selection and file IDs")
        try await wait { !app.isRefreshing }
        try fm.removeItem(at: root.appendingPathComponent("First.3mf"))
        try UpgradeValidation.makeModel(root.appendingPathComponent("First.3mf"), modelID: "54321")
        try await wait(attempts: 225) { app.projects.first { $0.id == initial.id }?.embeddedSourceURL == "https://makerworld.com/en/models/54321" }
        try check(app.projects.first { $0.id == initial.id }?.note == "NAS note retained", "NAS replacement must preserve note")
        print("NAS PASS: folder polling detected replacement and preserved note")
        try await wait { !app.isRefreshing }
        try fm.removeItem(at: second)
        try await wait(attempts: 225) { app.projects.count == 1 }
        print("NAS PASS: folder polling detected removal")
        try await wait { !app.isRefreshing }
        let offline = workspace.appendingPathComponent("Unavailable")
        try fm.moveItem(at: root, to: offline)
        app.refreshLibrary()
        try await wait { !app.isRefreshing }
        try check(app.projects.count == 1 && app.projects[0].note == "NAS note retained" && app.refreshMessage.contains("offline"), "Unavailable NAS root must preserve index and note")
        try fm.moveItem(at: offline, to: root)
        app.refreshLibrary()
        try await wait { !app.isRefreshing }
        try check(app.refreshMessage == "Up to date", "Restored NAS root must reconcile")
        print("NAS PASS: unavailable path simulation and recovery (mount remained connected)")
        app.selectedSection = .all
        try UpgradeValidation.makeModel(root.appendingPathComponent("FullSweep.3mf"), modelID: "87654")
        try await wait(attempts: 1600) { app.projects.count == 2 }
        print("NAS PASS: whole-library periodic sweep detected addition in All Models without notifications")
        print("NAS validation passed; all fixture data will be removed; database remained local")
    }

    private static func wait(attempts: Int = 100, _ condition: () -> Bool) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw Failure(description: "Timed out waiting for refresh")
    }
}
#endif
