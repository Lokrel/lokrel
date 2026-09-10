import AppKit
import Foundation
import UniformTypeIdentifiers

private struct TrashMove {
    let originalURL: URL
    let trashURL: URL
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var library: LibraryLocation?
    @Published private(set) var libraries: [LibraryLocation] = []
    @Published var isShowingLibraryManager = false
    @Published var isShowingWelcome = false
    @Published private(set) var scanProgress = ScanProgress()
    @Published private(set) var scanningLibraryName = ""
    @Published var showAllModels = UserDefaults.standard.bool(forKey: "showAllModels") {
        didSet { UserDefaults.standard.set(showAllModels, forKey: "showAllModels"); rebuildBrowserItems() }
    }
    @Published var expandedProjectFiles: Set<String> = []
    @Published var previewFileID: Int64?
    @Published var dragHint: String?
    @Published private(set) var recentDestinations = UserDefaults.standard.stringArray(forKey: "recentDestinations") ?? []
    @Published private(set) var projects: [ModelProject] = [] {
        didSet { rebuildBrowser() }
    }
    @Published private(set) var tags: [String] = []
    @Published var selectedProjectIDs: Set<String> = []
    @Published private(set) var filteredProjects: [ModelProject] = []
    @Published private(set) var browserItems: [BrowserItem] = []
    @Published private(set) var sourceGroups: [SourceGroup] = []
    @Published var expandedSourceGroups: Set<String> = [] { didSet { rebuildBrowserItems() } }
    @Published var cardSize: Double = UserDefaults.standard.object(forKey: "cardSize") as? Double ?? 190 {
        didSet { UserDefaults.standard.set(cardSize, forKey: "cardSize") }
    }
    @Published var focusedProjectID: String?
    @Published var previewProjectID: String?
    @Published var informationProject: ModelProject?
    @Published var folderCreationProject: ModelProject?
    @Published var transferRequest: TransferRequest?
    @Published var transferReport: TransferReport?
    @Published var showOrganizationPrompt = false
    @Published var isTransferring = false
    private var selectionAnchor: String?
    private var pendingOrganizationFingerprints: [String] = []
    @Published var selectedSection: LibrarySection = .all {
        didSet { reconcileSelection() }
    }
    @Published var layout: BrowserLayout = .grid
    @Published var sortOrder: BrowserSort = .filename {
        didSet { saveSortPreferences(); reconcileSelection() }
    }
    @Published var sortAscending = true {
        didSet { saveSortPreferences(); reconcileSelection() }
    }
    private var restoringSort = false

    private func saveSortPreferences() {
        guard !restoringSort, let library else { return }
        UserDefaults.standard.set(["order": sortOrder.rawValue, "ascending": sortAscending ? "yes" : "no"], forKey: "browserSort:" + library.rootPath)
    }

    private func restoreSortPreferences() {
        guard let library else { return }
        restoringSort = true
        defer { restoringSort = false }
        let saved = UserDefaults.standard.dictionary(forKey: "browserSort:" + library.rootPath)
        sortOrder = (saved?["order"] as? String).flatMap(BrowserSort.init(rawValue:)) ?? .filename
        sortAscending = saved?["ascending"] as? String != "no"
    }
    @Published var searchText = "" {
        didSet { reconcileSelection() }
    }
    @Published var filterTags: Set<String> = [] {
        didSet { reconcileSelection() }
    }
    @Published var filterFileTypes: Set<String> = [] {
        didSet { reconcileSelection() }
    }
    @Published var importDateFilter: ImportDateFilter = .any {
        didSet { reconcileSelection() }
    }
    @Published private(set) var filterUntagged = false {
        didSet { reconcileSelection() }
    }
    @Published var favoritesOnly = false {
        didSet { reconcileSelection() }
    }
    @Published var matchAllFilterTags = false {
        didSet { reconcileSelection() }
    }
    @Published var projectsPendingDeletion: [ModelProject] = []
    @Published var isShowingTagManager = false
    @Published private(set) var isScanning = false
    @Published private(set) var scanMessage = ""
    @Published private(set) var undoRevision = 0
    @Published var errorMessage: String?

    let undoManager = UndoManager()

    private let database: DatabaseStore?
    private let thumbnailService = ThumbnailService()
    private let automaticRefreshEnabled: Bool
    private var changeMonitor: LibraryChangeMonitor?
    private var refreshTask: Task<Void, Never>?
    private var inventory: [String: LibraryInventory.Stamp]?
    private var refreshGeneration = UUID()
    private var pendingRefresh = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshMessage = ""


    init(databasePath: String? = nil, initialLibraryURL: URL? = nil, scanOnLaunch: Bool = true) {
        automaticRefreshEnabled = scanOnLaunch
        do {
            database = try DatabaseStore(path: databasePath)
        } catch {
            database = nil
            errorMessage = error.localizedDescription
            return
        }
        do {
            libraries = try database?.libraries() ?? []
            if let initialLibraryURL { beginScan(url: initialLibraryURL) }
            else { try loadSavedLibrary(scanOnLaunch: scanOnLaunch) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedProjects: [ModelProject] {
        projects.filter { selectedProjectIDs.contains($0.id) }
    }

    var selectedProject: ModelProject? {
        guard selectedProjectIDs.count == 1, let id = selectedProjectIDs.first else { return nil }
        return projects.first { $0.id == id }
    }

    var hasSelection: Bool { !selectedProjectIDs.isEmpty }

    @Published private(set) var directoryTree: DirectoryNode?
    @Published private(set) var availableFileTypes: [String] = []
    private var scannedDirectoryPaths: [String] = []

    var activeFilterCount: Int {
        filterTags.count
            + filterFileTypes.count
            + (importDateFilter == .any ? 0 : 1)
            + (filterUntagged ? 1 : 0)
            + (favoritesOnly ? 1 : 0)
    }

    private var matchingProjects: [ModelProject] {
        let sectionProjects = projects.filter { project in
            switch selectedSection {
            case .all:
                return true
            case .favorites:
                return project.favorite
            case .recent:
                guard let modifiedAt = project.modifiedAt else { return false }
                return modifiedAt >= Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            case let .tag(name):
                return hasTag(name, project: project)
            case let .folder(path):
                return URL(fileURLWithPath: project.directoryPath).standardizedFileURL.path == path
            }
        }

        let filtered = sectionProjects.filter(matchesFilters)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filtered }
        return filtered.filter { project in
            project.displayName.localizedCaseInsensitiveContains(query)
                || project.author.localizedCaseInsensitiveContains(query)
                || project.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || project.files.contains(where: {
                    $0.filename.localizedCaseInsensitiveContains(query)
                })
        }
    }

    var canUndo: Bool {
        _ = undoRevision
        return undoManager.canUndo
    }

    var canRedo: Bool {
        _ = undoRevision
        return undoManager.canRedo
    }

    var undoMenuTitle: String {
        _ = undoRevision
        return undoManager.undoMenuItemTitle
    }

    var redoMenuTitle: String {
        _ = undoRevision
        return undoManager.redoMenuItemTitle
    }

    func selectProject(_ projectID: String, extending: Bool, range: Bool = false) {
        previewFileID = nil
        focusedProjectID = projectID
        if range, let anchor = selectionAnchor,
           let start = browserItems.firstIndex(where: { $0.id == anchor }),
           let end = browserItems.firstIndex(where: { $0.id == projectID }) {
            selectedProjectIDs = Set(browserItems[min(start, end)...max(start, end)].map(\.id))
            return
        }
        selectionAnchor = projectID
        if extending {
            if selectedProjectIDs.contains(projectID) {
                selectedProjectIDs.remove(projectID)
            } else {
                selectedProjectIDs.insert(projectID)
            }
        } else {
            selectedProjectIDs = [projectID]
        }
    }

    func dragPayload(for projectID: String) -> String {
        let ids = selectedProjectIDs.contains(projectID)
            ? filteredProjects.map(\.id).filter(selectedProjectIDs.contains)
            : [projectID]
        return ids.joined(separator: "\n")
    }

    func selectModelFile(projectID: String, fileID: Int64) {
        selectProject(projectID, extending: false)
        previewFileID = fileID
    }

    func prepareDrag(_ key: String) -> ModelDragContent? {
        guard !isScanning, !isTransferring else { return nil }
        if let choice = ModelDragContent.fileChoice(key),
           let project = projects.first(where: { $0.id == choice.projectID }),
           let file = project.files.first(where: { $0.id == choice.fileID && $0.isPrimaryModel }) {
            return ModelDragContent(projectID: project.id, file: file.url)
        }
        let ids = actionProjectIDs(for: key)
        let items = filteredProjects.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return nil }
        let content = ModelDragContent(projects: items)
        if content.requiresFileChoice {
            dragHint = L10n.text("This selection contains multiple model files. Expand Model Files and drag the specific 3MF or STL file you need.")
            expandedProjectFiles.formUnion(items.filter { $0.files.filter(\.isPrimaryModel).count > 1 }.map(\.id))
        } else { dragHint = nil }
        return content
    }

    func actionProjectIDs(for projectID: String) -> Set<String> {
        if selectedProjectIDs.count > 1, selectedProjectIDs.contains(projectID) {
            return selectedProjectIDs
        }
        return [projectID]
    }

    @discardableResult
    func assignTagFromDrop(_ name: String, payloads: [String]) -> Bool {
        let validIDs = Set(projects.map(\.id))
        let droppedIDs = Set(payloads.flatMap { $0.split(separator: "\n").map(String.init) })
            .intersection(validIDs)
        guard !droppedIDs.isEmpty else { return false }
        setTag(name, assigned: true, projectIDs: droppedIDs)
        return true
    }

    func setFilterTag(_ name: String, enabled: Bool) {
        if enabled { filterTags.insert(name) }
        else { filterTags.remove(name) }
        if filterTags.count < 2 { matchAllFilterTags = false }
    }

    func setFilterUntagged(_ enabled: Bool) {
        if enabled { matchAllFilterTags = false }
        filterUntagged = enabled
    }

    func setFilterFileType(_ fileType: String, enabled: Bool) {
        if enabled { filterFileTypes.insert(fileType) }
        else { filterFileTypes.remove(fileType) }
    }

    func clearFilters() {
        filterTags.removeAll()
        filterFileTypes.removeAll()
        importDateFilter = .any
        filterUntagged = false
        favoritesOnly = false
        matchAllFilterTags = false
    }

    func chooseLibrary() {
        guard !isScanning, !isTransferring else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose Model Library")
        panel.prompt = L10n.text("Add Library")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        presentFilePanel(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(true, forKey: "welcomeDismissed")
            self?.isShowingWelcome = false
            self?.isShowingLibraryManager = false
            self?.openLibrary(url)
        }
    }

    func dismissWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomeDismissed")
        isShowingWelcome = false
    }

    func openLibrary(_ url: URL) {
        guard let database, !isScanning, !isTransferring else { return }
        do {
            if let saved = try database.restoreLibrary(rootURL: url) { try displayLibrary(saved) }
            else { beginScan(url: url) }
        } catch { errorMessage = error.localizedDescription }
    }

    func removeLibrary(_ location: LibraryLocation) {
        guard let database, !isScanning, !isTransferring else { return }
        do {
            try database.removeLibrary(id: location.id)
            libraries = try database.libraries()
            if library?.id == location.id {
                if let next = libraries.first { try displayLibrary(next) }
                else {
                    stopMonitoring()
                    library = nil
                    projects = []
                    tags = []
                    directoryTree = nil
                    resetLibrarySelection()
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func resetLibrarySelection() {
        selectedProjectIDs = []
        focusedProjectID = nil
        previewProjectID = nil
        previewFileID = nil
        selectedSection = .all
        searchText = ""
        clearFilters()
        expandedSourceGroups = []
        expandedProjectFiles = []
        scannedDirectoryPaths = []
        showOrganizationPrompt = false
        undoManager.removeAllActions()
        undoRevision &+= 1
    }

    private func displayLibrary(_ location: LibraryLocation) throws {
        guard let database else { return }
        stopMonitoring()
        resetLibrarySelection()
        library = location
        restoreSortPreferences()
        projects = try database.projects(libraryID: location.id)
        tags = try database.allTags(libraryID: location.id)
        reconcileSelection()
        libraries = try database.libraries()
        scanMessage = L10n.format("%ld models · Saved library", projects.count)
        startMonitoring()
    }

    func rescan() {
        guard let library else { return }
        beginScan(url: URL(fileURLWithPath: library.rootPath))
    }

    func toggleFavorite(projectID: String) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        setFavorite(!project.favorite, projectID: projectID)
    }

    func saveNote(_ note: String, projectID: String) {
        guard let database,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let previous = projects[index].note
        guard previous != note else { return }
        do {
            try database.setNote(note, projectID: projectID)
            projects[index].note = note
            registerUndo(L10n.text("Edit Note")) { target in
                target.saveNote(previous, projectID: projectID)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveEditableDetails(_ details: EditableModelDetails, projectID: String) {
        guard let database,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let previous = editableDetails(for: projects[index])
        do {
            try database.setEditableDetails(details, projectID: projectID)
            let trimmedName = details.customName.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index].customName = trimmedName.isEmpty ? nil : trimmedName
            projects[index].author = details.author.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index].sourceURL = details.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index].license = details.license.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index].modelDescription = details.modelDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
            registerUndo(L10n.text("Edit Model")) { target in
                target.saveEditableDetails(previous, projectID: projectID)
            }
            reconcileSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    func openSourceURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = L10n.text("Please enter a valid http or https link.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func createTag(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let database else { return false }
        do {
            guard !tags.contains(where: {
                $0.caseInsensitiveCompare(normalized) == .orderedSame
            }) else {
                errorMessage = L10n.text("A tag with this name already exists.")
                return false
            }
            try database.createTag(normalized)
            reloadTags()
            registerUndo(L10n.text("Add Tag")) { target in target.deleteTag(normalized) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameTag(_ oldName: String, to newName: String) {
        let normalized = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != oldName, let database else { return }
        let previousSelection = selectedProjectIDs
        do {
            try database.renameTag(oldName, to: normalized)
            if selectedSection == .tag(oldName) { selectedSection = .tag(normalized) }
            if filterTags.remove(oldName) != nil { filterTags.insert(normalized) }
            try reloadProjects()
            reloadTags()
            selectedProjectIDs = previousSelection
            reconcileSelection()
            registerUndo(L10n.text("Rename Tag")) { target in
                target.renameTag(normalized, to: oldName)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteTag(_ name: String) {
        do {
            guard let database, let snapshot = try database.tagSnapshot(name) else { return }
            try database.deleteTag(name)
            if selectedSection == .tag(name) { selectedSection = .all }
            filterTags.remove(name)
            try reloadProjects()
            reloadTags()
            registerUndo(L10n.text("Delete Tag")) { target in target.restoreTag(snapshot) }
        } catch { errorMessage = error.localizedDescription }
    }

    func moveTag(_ name: String, offset: Int) {
        guard let index = tags.firstIndex(of: name) else { return }
        let destination = index + offset
        guard tags.indices.contains(destination) else { return }
        let previousOrder = tags
        var newOrder = tags
        newOrder.swapAt(index, destination)
        setTagOrder(newOrder, undoOrder: previousOrder)
    }

    func tagIsAssignedToAll(_ name: String, projectIDs: Set<String>) -> Bool {
        !projectIDs.isEmpty && projectIDs.allSatisfy { id in
            projects.first(where: { $0.id == id }).map { hasTag(name, project: $0) } ?? false
        }
    }

    func tagIsAssignedToAny(_ name: String, projectIDs: Set<String>) -> Bool {
        projectIDs.contains { id in
            projects.first(where: { $0.id == id }).map { hasTag(name, project: $0) } ?? false
        }
    }

    func addTag(_ name: String, projectID: String) {
        setTag(name, assigned: true, projectIDs: [projectID])
    }

    func removeTag(_ name: String, projectID: String) {
        setTag(name, assigned: false, projectIDs: [projectID])
    }

    func toggleTag(_ name: String, projectID: String) {
        toggleTag(name, projectIDs: [projectID])
    }

    func toggleTag(_ name: String, projectIDs: Set<String>) {
        let shouldAssign = !tagIsAssignedToAll(name, projectIDs: projectIDs)
        setTag(name, assigned: shouldAssign, projectIDs: projectIDs)
    }

    func assignTagShortcut(at index: Int) {
        guard tags.indices.contains(index), !selectedProjectIDs.isEmpty else { return }
        setTag(tags[index], assigned: true, projectIDs: selectedProjectIDs)
    }

    func useAssociatedImage(_ file: ModelFile, projectID: String) {
        setCoverPath(file.path, projectID: projectID)
    }

    func chooseCustomCover(projectID: String) {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose Cover Image")
        panel.prompt = L10n.text("Set Cover")
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        Task {
            do {
                let path = try await thumbnailService.copyCustomCover(
                    from: sourceURL,
                    projectID: projectID
                )
                setCoverPath(path, projectID: projectID)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func resetCover(projectID: String) {
        setCoverPath(nil, projectID: projectID)
    }

    func ensureThumbnail(for project: ModelProject) {
        guard project.displayCoverURL == nil, project.thumbnailPath == nil else { return }
        Task {
            do {
                guard let path = try await thumbnailService.previewThumbnail(for: project),
                      let database,
                      let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
                try database.setThumbnail(path: path, projectID: project.id)
                projects[index].thumbnailPath = path
            } catch {
                // A missing or malformed embedded thumbnail falls back to the default icon.
            }
        }
    }

    func openPrimaryFile(_ project: ModelProject) {
        guard let file = project.primaryFile else { return }
        NSWorkspace.shared.open(file.url)
    }

    func revealInFinder(_ project: ModelProject) {
        if let file = project.primaryFile {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } else {
            NSWorkspace.shared.open(project.directoryURL)
        }
    }

    func revealDirectory(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func requestDelete(_ project: ModelProject) {
        guard !isScanning, !isTransferring else { return }
        if selectedProjectIDs.count > 1, selectedProjectIDs.contains(project.id) {
            projectsPendingDeletion = selectedProjects
        } else {
            projectsPendingDeletion = [project]
        }
    }

    func requestDeleteSelectedProjects() {
        guard !isScanning, !isTransferring else { return }
        projectsPendingDeletion = selectedProjects
    }

    func cancelDelete() {
        projectsPendingDeletion = []
    }

    func movePendingProjectsToTrash() {
        let pending = projectsPendingDeletion
        projectsPendingDeletion = []
        trashProjects(pending)
    }

    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        undoRevision &+= 1
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        undoRevision &+= 1
    }

    private func loadSavedLibrary(scanOnLaunch: Bool) throws {
        guard let database else { return }
        guard let saved = try database.mostRecentLibrary() else {
            isShowingWelcome = !UserDefaults.standard.bool(forKey: "welcomeDismissed")
            return
        }
        try displayLibrary(saved)

    }

    private func beginScan(url: URL) {
        guard !isScanning, !isTransferring else { return }
        stopMonitoring()
        isScanning = true
        scanProgress = ScanProgress()
        scanningLibraryName = url.lastPathComponent
        scanMessage = L10n.text("Scanning…")
        Task { await scan(url: url.resolvingSymlinksInPath().standardizedFileURL) }
    }

    private func scan(url: URL) async {
        guard let database else { return }
        isScanning = true
        scanMessage = L10n.text("Scanning…")
        defer { isScanning = false; startMonitoring() }

        do {
            let tracked = try await Task.detached(priority: .userInitiated) {
                try database.projects(rootURL: url)
            }.value
            let reportProgress: @Sendable (ScanProgress) -> Void = { [weak self] value in
                Task { @MainActor in
                    guard let self, self.isScanning else { return }
                    self.scanProgress = value
                }
            }
            let result = try await LibraryScanner.scan(rootURL: url, trackedProjects: tracked, forceSources: true, progress: reportProgress)
            scanProgress = ScanProgress(stage: .saving, total: result.projects.count)
            let saved = try await Task.detached(priority: .userInitiated) {
                let location = try database.applyScan(result, rootURL: url, progress: reportProgress)
                return (location: location, libraries: try database.libraries(),
                        projects: try database.projects(libraryID: location.id),
                        tags: try database.allTags(libraryID: location.id))
            }.value
            if library?.id != saved.location.id { resetLibrarySelection() }
            library = saved.location
            restoreSortPreferences()
            libraries = saved.libraries
            scannedDirectoryPaths = result.directoryPaths
            projects = saved.projects
            tags = saved.tags
            undoManager.removeAllActions()
            undoRevision &+= 1
            scanMessage = L10n.format("%ld models · %@s", projects.count, result.duration.formatted(.number.precision(.fractionLength(1))))
            reconcileSelection()
            offerOrganization()
        } catch {
            errorMessage = error.localizedDescription
            scanMessage = L10n.text("Scan failed")
        }
    }

    private func stopMonitoring() {
        refreshGeneration = UUID()
        changeMonitor?.stop()
        changeMonitor = nil
        refreshTask?.cancel()
        refreshTask = nil
        inventory = nil
        isRefreshing = false
        refreshMessage = ""
        pendingRefresh = false
    }

    private func startMonitoring() {
        guard automaticRefreshEnabled, let library, changeMonitor == nil else { return }
        let root = URL(fileURLWithPath: library.rootPath)
        changeMonitor = LibraryChangeMonitor(root: root, visibleFolder: { [weak self] in
            if case let .folder(path) = self?.selectedSection { return path }
            return nil
        }, refresh: { [weak self] scopes in self?.refreshLibrary(scopes: scopes) })
        refreshLibrary()
    }

    func refreshLibrary(scopes requestedScopes: [String]? = nil) {
        guard let library, let database, !isScanning else { return }
        guard !isTransferring, !isRefreshing else { pendingRefresh = true; return }
        pendingRefresh = false
        let root = URL(fileURLWithPath: library.rootPath)
        let generation = refreshGeneration
        let previous = inventory
        let scopes = previous == nil ? nil : requestedScopes.map { LibraryInventory.scopes($0, root: root.path) }
        isRefreshing = true
        refreshMessage = L10n.text("Checking for changes…")
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.refreshGeneration == generation {
                    self.isRefreshing = false
                    if self.pendingRefresh { self.retryRefresh(generation: generation) }
                }
            }
            do {
                let before = try await Task.detached(priority: .utility) { try LibraryInventory.read(root: root, scopes: scopes) }.value
                guard !Task.isCancelled, self.refreshGeneration == generation else { return }
                let old = previous?.filter { path, _ in scopes == nil || scopes!.contains { path == $0 || path.hasPrefix($0 + "/") } }
                if old == before {
                    self.refreshMessage = L10n.text("Up to date")
                    return
                }
                try await Task.sleep(for: .seconds(1))
                let after = try await Task.detached(priority: .utility) { try LibraryInventory.read(root: root, scopes: scopes) }.value
                guard !Task.isCancelled, self.refreshGeneration == generation else { return }
                guard before == after else {
                    self.refreshMessage = L10n.text("Waiting for files to finish copying…")
                    self.retryRefresh(generation: generation)
                    return
                }
                let changedScopes: [String]?
                if let old {
                    let changed = Set(old.keys).union(after.keys).filter { old[$0] != after[$0] }
                    changedScopes = LibraryInventory.scopes(changed.map { path in
                        let stamp = after[path] ?? old[path]!
                        return stamp.directory ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path
                    }, root: root.path)
                } else { changedScopes = nil }
                self.refreshMessage = L10n.text("Updating models…")
                let tracked = try await Task.detached(priority: .utility) { try database.projects(rootURL: root) }.value
                let result = try await LibraryScanner.scan(rootURL: root, trackedProjects: tracked, scopePaths: changedScopes, deferUnreadableModels: true)
                let final = try await Task.detached(priority: .utility) { try LibraryInventory.read(root: root, scopes: scopes) }.value
                guard !Task.isCancelled, self.refreshGeneration == generation, !self.isTransferring else { return }
                guard final == after else {
                    self.refreshMessage = L10n.text("Waiting for files to finish copying…")
                    self.retryRefresh(generation: generation)
                    return
                }
                let saved = try await Task.detached(priority: .utility) {
                    let location = try database.applyScan(result, rootURL: root)
                    return (location, try database.projects(libraryID: location.id), try database.allTags(libraryID: location.id))
                }.value
                guard !Task.isCancelled, self.refreshGeneration == generation else { return }
                self.library = saved.0
                self.tags = saved.2
                if let changedScopes {
                    self.scannedDirectoryPaths.removeAll { path in changedScopes.contains { path == $0 || path.hasPrefix($0 + "/") } }
                    self.scannedDirectoryPaths += result.directoryPaths
                } else { self.scannedDirectoryPaths = result.directoryPaths }
                if self.projects != saved.1 { self.projects = saved.1 }
                else { self.rebuildBrowser() }
                var merged = previous ?? [:]
                if let scopes { merged = merged.filter { path, _ in !scopes.contains { path == $0 || path.hasPrefix($0 + "/") } } }
                else { merged.removeAll() }
                merged.merge(final, uniquingKeysWith: { _, new in new })
                for path in result.deferredPaths { merged.removeValue(forKey: path) }
                self.inventory = merged
                self.refreshMessage = result.deferredPaths.isEmpty ? L10n.text("Up to date") : L10n.format("%ld models unavailable · Will retry", result.deferredPaths.count)
                self.scanMessage = L10n.format("%ld models · Updated", self.projects.count)
            } catch is CancellationError {
            } catch {
                guard self.refreshGeneration == generation else { return }
                self.refreshMessage = FileManager.default.isReadableFile(atPath: root.path)
                    ? L10n.text("Update incomplete · Will retry") : L10n.text("Library offline · Showing saved models")
            }
        }
    }

    private func retryRefresh(generation: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.refreshGeneration == generation else { return }
            self.refreshLibrary()
        }
    }

#if DEBUG
    func disableNotificationsForValidation() { changeMonitor?.disableNotificationsForValidation() }
#endif

    private func reloadTags() {
        guard let database, let library else { return }
        do {
            tags = try database.allTags(libraryID: library.id)
            filterTags.formIntersection(tags)
            if filterTags.count < 2 { matchAllFilterTags = false }
        } catch { errorMessage = error.localizedDescription }
    }

    private func reloadProjects() throws {
        guard let database, let library else { return }
        projects = try database.projects(libraryID: library.id)
        reconcileSelection()
    }

    private func rebuildBrowser() {
        if let library {
            directoryTree = DirectoryNode.build(rootPath: library.rootPath, projects: projects, directoryPaths: scannedDirectoryPaths)
        }
        availableFileTypes = Set(projects.flatMap { $0.files.filter(\.isPrimaryModel).map { $0.fileExtension.lowercased() } }).sorted()
        sourceGroups = SourceGrouping.groups(projects)
        reconcileSelection()
    }

    private func rebuildBrowserItems() {
        let groups = SourceGrouping.groups(filteredProjects)
        let byProject = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            group.projects.map { ($0.id, group) }
        })
        var emitted: Set<String> = []
        var items: [BrowserItem] = []
        for project in filteredProjects {
            if let group = byProject[project.id] {
                guard emitted.insert(group.id).inserted else { continue }
                items.append(BrowserItem(project: group.projects[0], group: group))
                if showAllModels || expandedSourceGroups.contains(group.id) {
                    items += group.projects.dropFirst().map { BrowserItem(project: $0, isGroupMember: true) }
                }
            } else {
                items.append(BrowserItem(project: project))
            }
        }
        browserItems = items
        let visible = Set(items.map(\.id))
        selectedProjectIDs.formIntersection(visible)
        if let focusedProjectID, !visible.contains(focusedProjectID) { self.focusedProjectID = nil }
        if let previewProjectID, !visible.contains(previewProjectID) { self.previewProjectID = nil }
    }

    private func reconcileSelection() {
        filteredProjects = sortOrder.sorted(matchingProjects, ascending: sortAscending, tagOrder: tags)
        rebuildBrowserItems()
        let visibleIDs = Set(filteredProjects.map(\.id))
        selectedProjectIDs.formIntersection(visibleIDs)
    }

    private func setFavorite(_ favorite: Bool, projectID: String) {
        guard let database,
              let index = projects.firstIndex(where: { $0.id == projectID }),
              projects[index].favorite != favorite else { return }
        let previous = projects[index].favorite
        do {
            try database.setFavorite(favorite, projectID: projectID)
            projects[index].favorite = favorite
            registerUndo(favorite ? L10n.text("Add Favorite") : L10n.text("Remove Favorite")) { target in
                target.setFavorite(previous, projectID: projectID)
            }
            reconcileSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    private func setTag(_ name: String, assigned: Bool, projectIDs: Set<String>) {
        let changedIDs = projectIDs.filter { id in
            guard let project = projects.first(where: { $0.id == id }) else { return false }
            return hasTag(name, project: project) != assigned
        }
        guard !changedIDs.isEmpty else { return }

        guard let database else { return }
        do {
            try database.setTag(name, assigned: assigned, projectIDs: Array(changedIDs))
            for index in projects.indices where changedIDs.contains(projects[index].id) {
                if assigned {
                    projects[index].tags.append(name)
                    sortProjectTags(at: index)
                } else {
                    projects[index].tags.removeAll {
                        $0.caseInsensitiveCompare(name) == .orderedSame
                    }
                }
            }
            registerUndo(assigned ? L10n.text("Add Tag") : L10n.text("Remove Tag")) { target in
                target.setTag(name, assigned: !assigned, projectIDs: Set(changedIDs))
            }
            reconcileSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    private func setTagOrder(_ newOrder: [String], undoOrder: [String]) {
        guard let database else { return }
        do {
            try database.setTagOrder(newOrder)
            tags = newOrder
            for index in projects.indices { sortProjectTags(at: index) }
            registerUndo(L10n.text("Reorder Tags")) { target in
                target.setTagOrder(undoOrder, undoOrder: newOrder)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func restoreTag(_ snapshot: TagSnapshot) {
        guard let database else { return }
        do {
            try database.restoreTag(snapshot)
            try reloadProjects()
            reloadTags()
            registerUndo(L10n.text("Delete Tag")) { target in target.deleteTag(snapshot.name) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func trashProjects(_ projectsToTrash: [ModelProject]) {
        guard let database, !projectsToTrash.isEmpty else { return }
        let projectIDs = projectsToTrash.map(\.id)
        let fileURLs = projectsToTrash
            .flatMap(\.files)
            .map(\.url)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        var moves: [TrashMove] = []

        do {
            for originalURL in fileURLs {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(
                    at: originalURL,
                    resultingItemURL: &resultingURL
                )
                if let trashURL = resultingURL as URL? {
                    moves.append(TrashMove(originalURL: originalURL, trashURL: trashURL))
                }
            }
            try database.setProjectsMissing(true, projectIDs: projectIDs)
            try reloadProjects()
            registerUndo(projectIDs.count == 1 ? L10n.text("Delete Model") : L10n.text("Delete Models")) { target in
                target.restoreTrashedProjects(projectIDs: projectIDs, moves: moves)
            }
        } catch {
            rollbackTrashMoves(moves)
            errorMessage = L10n.format("Could not move the model to Trash: %@", error.localizedDescription)
        }
    }

    private func restoreTrashedProjects(projectIDs: [String], moves: [TrashMove]) {
        guard let database else { return }
        var restoredMoves: [TrashMove] = []
        do {
            for move in moves {
                try FileManager.default.moveItem(at: move.trashURL, to: move.originalURL)
                restoredMoves.append(move)
            }
            try database.setProjectsMissing(false, projectIDs: projectIDs)
            try reloadProjects()
            registerUndo(projectIDs.count == 1 ? L10n.text("Delete Model") : L10n.text("Delete Models")) { target in
                let restoredProjects = target.projects.filter { projectIDs.contains($0.id) }
                target.trashProjects(restoredProjects)
            }
        } catch {
            for move in restoredMoves.reversed() {
                try? FileManager.default.moveItem(at: move.originalURL, to: move.trashURL)
            }
            errorMessage = L10n.format("Could not restore the model from Trash: %@", error.localizedDescription)
        }
    }

    private func rollbackTrashMoves(_ moves: [TrashMove]) {
        for move in moves.reversed() {
            try? FileManager.default.moveItem(at: move.trashURL, to: move.originalURL)
        }
    }

    private func registerUndo(_ actionName: String, action: @escaping (AppModel) -> Void) {
        undoManager.registerUndo(withTarget: self) { target in action(target) }
        undoManager.setActionName(actionName)
        undoRevision &+= 1
    }

    private func hasTag(_ name: String, project: ModelProject) -> Bool {
        project.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func sortProjectTags(at index: Int) {
        let order = Dictionary(uniqueKeysWithValues: tags.enumerated().map {
            ($1.lowercased(), $0)
        })
        projects[index].tags.sort {
            (order[$0.lowercased()] ?? Int.max) < (order[$1.lowercased()] ?? Int.max)
        }
    }

    private func editableDetails(for project: ModelProject) -> EditableModelDetails {
        EditableModelDetails(
            customName: project.customName ?? "",
            author: project.author,
            sourceURL: project.sourceURL,
            license: project.license,
            modelDescription: project.modelDescription
        )
    }

    private func matchesFilters(_ project: ModelProject) -> Bool {
        if favoritesOnly, !project.favorite { return false }

        let matchesSelectedTags: Bool
        if filterTags.isEmpty {
            matchesSelectedTags = false
        } else {
            let matches = filterTags.map { hasTag($0, project: project) }
            matchesSelectedTags = matchAllFilterTags
                ? !matches.contains(false)
                : matches.contains(true)
        }
        if filterUntagged {
            if !project.tags.isEmpty, !matchesSelectedTags { return false }
        } else if !filterTags.isEmpty, !matchesSelectedTags {
            return false
        }

        if !filterFileTypes.isEmpty,
           !project.files.contains(where: {
               $0.isPrimaryModel && filterFileTypes.contains($0.fileExtension.lowercased())
           }) {
            return false
        }

        return matchesImportDate(project.importedAt)
    }

    private func matchesImportDate(_ date: Date?) -> Bool {
        guard importDateFilter != .any else { return true }
        guard let date else { return false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        switch importDateFilter {
        case .any: return true
        case .today: return date >= today
        case .lastSevenDays: return date >= sevenDaysAgo
        case .lastThirtyDays: return date >= thirtyDaysAgo
        case .earlier: return date < thirtyDaysAgo
        }
    }

    private func setCoverPath(_ path: String?, projectID: String) {
        guard let database,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let previous = projects[index].coverOverridePath
        guard previous != path else { return }
        do {
            try database.setCoverOverride(path: path, projectID: projectID)
            projects[index].coverOverridePath = path
            registerUndo(L10n.text("Change Cover")) { target in
                target.setCoverPath(previous, projectID: projectID)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

extension AppModel {
    var organizationCandidates: [SourceGroup] { sourceGroups.filter(\.isScattered) }

    func navigate(key: UInt16, columns: Int, extending: Bool) {
        let current = focusedProjectID.flatMap { id in browserItems.firstIndex { $0.id == id } }
        guard let index = BrowserNavigation.destination(current: current, count: browserItems.count, columns: columns, key: key) else { return }
        selectProject(browserItems[index].id, extending: false, range: extending)
    }

    func toggleGroup(_ id: String) {
        guard !showAllModels else { return }
        if !expandedSourceGroups.insert(id).inserted { expandedSourceGroups.remove(id) }
    }

    func togglePreview() {
        if previewProjectID != nil { previewProjectID = nil }
        else if let project = selectedProject { previewProjectID = project.id }
    }

    func navigatePreview(_ offset: Int) {
        guard let id = previewProjectID, let current = browserItems.firstIndex(where: { $0.id == id }) else { return }
        let next = current + offset
        guard browserItems.indices.contains(next) else { return }
        let project = browserItems[next].project
        selectProject(project.id, extending: false)
        previewProjectID = project.id
    }

    func requestTransfer(_ project: ModelProject, copy: Bool, destination: URL? = nil) {
        guard !isScanning, !isTransferring else { return }
        let ids = actionProjectIDs(for: project.id)
        let items = projects.filter { ids.contains($0.id) }
        if let destination {
            transferRequest = TransferRequest(projects: items, groups: [], copy: copy, destination: destination)
        } else {
            chooseDestination(project.directoryURL) { [weak self] url in
                guard let url else { return }
                self?.transferRequest = TransferRequest(projects: items, groups: [], copy: copy, destination: url)
            }
        }
    }

    func rememberDestination(_ url: URL) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        recentDestinations = Array(([path] + recentDestinations.filter { $0 != path }).prefix(5))
        UserDefaults.standard.set(recentDestinations, forKey: "recentDestinations")
    }

    private var organizationPreferenceKey: String { "organizationSeen:" + (library?.rootPath ?? "") }

    fileprivate func offerOrganization() {
        let seen = Set(UserDefaults.standard.stringArray(forKey: organizationPreferenceKey) ?? [])
        pendingOrganizationFingerprints = organizationCandidates.map(\.fingerprint).filter { !seen.contains($0) }
        showOrganizationPrompt = !isScanning && !pendingOrganizationFingerprints.isEmpty
    }

    func finishScanPresentation() {
        if !isScanning { offerOrganization() }
    }

    func dismissOrganizationPrompt() {
        let seen = Set(UserDefaults.standard.stringArray(forKey: organizationPreferenceKey) ?? [])
        UserDefaults.standard.set(Array(seen.union(pendingOrganizationFingerprints)), forKey: organizationPreferenceKey)
        pendingOrganizationFingerprints = []
        showOrganizationPrompt = false
    }

    func reviewOrganization() {
        dismissOrganizationPrompt()
        let groups = organizationCandidates
        guard !groups.isEmpty else { return }
        transferRequest = TransferRequest(projects: groups.flatMap(\.projects), groups: groups, copy: false)
    }

    func performTransfer(_ plans: [ProjectTransfer], copy: Bool, parent: URL, skipped: [ModelProject] = []) {
        guard let database, let library, !isScanning, !isTransferring else { return }
        isTransferring = true
        transferRequest = nil
        Task {
            let root = URL(fileURLWithPath: library.rootPath)
            let report = await Task.detached(priority: .userInitiated) {
                ProjectTransferService.execute(plans, copy: copy, parent: parent, skipped: skipped, recover: { actual in
                    try database.recordTransfer(actual, copy: false, root: root)
                }) { plan in
                    try database.recordTransfer(plan, copy: copy, root: root)
                }
            }.value
            do { try reloadProjects() } catch { errorMessage = error.localizedDescription }
            undoManager.removeAllActions()
            undoRevision &+= 1
            isTransferring = false
            if pendingRefresh { refreshLibrary() }
            if report.succeeded > 0 { rememberDestination(parent) }
            transferReport = report
        }
    }

    func createFolder(parent: URL, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw TransferFailure(message: L10n.text("Enter a folder name without / or :."))
        }
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TransferFailure(message: L10n.text("A file or folder with this name already exists."))
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        folderCreationProject = nil
        rescan()
    }
}
