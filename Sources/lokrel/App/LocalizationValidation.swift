#if DEBUG
import Foundation

@MainActor
enum LocalizationValidation {
    static func run() throws {
        let chinese = CommandLine.arguments.contains("--expect-chinese")
        print("Selected localization: \(L10n.bundle.preferredLocalizations); count format: \(L10n.text("%ld projects")); rendered: \(L10n.format("%ld projects", 1))")
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "LocalizationValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try check(L10n.text("All Models") == (chinese ? "全部模型" : "All Models"), "Wrong preferred language")
        try check(L10n.format("%ld projects", 1) == (chinese ? "1 个项目" : "1 project"), "Singular project count")
        try check(L10n.format("%ld projects", 2) == (chinese ? "2 个项目" : "2 projects"), "Plural project count")
        try check(L10n.format("%ld files", 0) == (chinese ? "0 个文件" : "0 files"), "Zero file count")
        try check(L10n.format("%ld models", 1) == (chinese ? "1 个模型" : "1 model"), "Single model scan total")
        try check(L10n.format("%ld files found", 1) == (chinese ? "已发现 1 个文件" : "1 file found"), "Single discovered file")
        try check(L10n.format("%ld models · %@s", 1, "2.5") == (chinese ? "1 个模型 · 2.5 秒" : "1 model · 2.5s"), "Plural with additional argument")
        let userText = "My 模型 100% / %@"
        try check(L10n.format("Sort by %@", userText).contains(userText), "Dynamic content must remain literal")
        var languageKeys: [Set<String>] = []
        for language in ["en", "zh-Hans"] {
            let folder = L10n.bundle.bundleURL.appendingPathComponent(language + ".lproj")
            let strings = try PropertyListSerialization.propertyList(from: Data(contentsOf: folder.appendingPathComponent("Localizable.strings")), format: nil) as! [String: String]
            let plurals = try PropertyListSerialization.propertyList(from: Data(contentsOf: folder.appendingPathComponent("Localizable.stringsdict")), format: nil) as! [String: Any]
            languageKeys.append(Set(strings.keys).union(plurals.keys))
            try check(strings.values.allSatisfy { !$0.isEmpty }, "Empty translation")
        }
        try check(languageKeys[0] == languageKeys[1], "Language resources must cover identical keys")
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("lokrel-localization-\(UUID())").resolvingSymlinksInPath()
        let root = workspace.appendingPathComponent("Library")
        let destination = workspace.appendingPathComponent("Copied")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        try UpgradeValidation.makeModel(root.appendingPathComponent("模型 100%.3mf"), modelID: "12345")
        let db = try DatabaseStore(path: workspace.appendingPathComponent("index.sqlite").path)
        let library = try db.applyScan(LibraryScanner.scanSynchronously(rootURL: root), rootURL: root)
        let project = try db.projects(libraryID: library.id)[0]
        try db.setNote(userText, projectID: project.id)
        try db.createTag("自定义 Tag 100%")
        try db.setTag("自定义 Tag 100%", assigned: true, projectIDs: [project.id])
        let tagged = try db.projects(libraryID: library.id)[0]
        let plans = try ProjectTransferService.plan(request: TransferRequest(projects: [tagged], groups: [], copy: true), parent: destination, selectedGroups: [])
        let report = ProjectTransferService.execute(plans, copy: true, parent: destination) { try db.recordTransfer($0, copy: true, root: root) }
        try check(report.succeeded == 1 && report.text.contains(chinese ? "成功 1 个" : "1 succeeded") && report.text.contains("模型 100%"), "Localized copy report must describe actual operation and preserve names")
        for file in plans.flatMap(\.files) {
            let equal = try ProjectTransferService.digest(file.source) == ProjectTransferService.digest(file.destination)
            try check(equal, "Localized operation must preserve file contents")
        }
        let copied = try db.projects(libraryID: library.id).first { $0.directoryPath == destination.path }!
        try check(copied.note == userText && copied.tags == tagged.tags, "Localized transfer must preserve notes and tags")
        print("Localization validation passed: \(chinese ? "Simplified Chinese" : "English"), \(languageKeys[0].count) keys, plurals, format arguments, user text preservation")
        print("Localization bundle: \(L10n.bundle.bundleURL.path)")
    }
}
#endif
