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
    @Published private(set) var projects: [ModelProject] = []
    @Published private(set) var tags: [String] = []
    @Published var selectedProjectIDs: Set<String> = []
    @Published var selectedSection: LibrarySection = .all {
        didSet { reconcileSelection() }
    }
    @Published var layout: BrowserLayout = .grid
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

    init() {
        do {
            database = try DatabaseStore()
        } catch {
            database = nil
            errorMessage = error.localizedDescription
            return
        }
        do {
            try loadSavedLibrary()
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

    var directoryTree: DirectoryNode? {
        guard let library else { return nil }
        return DirectoryNode.build(rootPath: library.rootPath, projects: projects)
    }

    var availableFileTypes: [String] {
        Array(Set(projects.flatMap { project in
            project.files.filter(\.isPrimaryModel).map { $0.fileExtension.lowercased() }
        })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var activeFilterCount: Int {
        filterTags.count
            + filterFileTypes.count
            + (importDateFilter == .any ? 0 : 1)
            + (filterUntagged ? 1 : 0)
            + (favoritesOnly ? 1 : 0)
    }

    var filteredProjects: [ModelProject] {
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

    func selectProject(_ projectID: String, extending: Bool) {
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
        let panel = NSOpenPanel()
        panel.title = "Choose Model Library"
        panel.prompt = "Choose Library"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginScan(url: url)
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
            registerUndo("Edit Note") { target in
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
            registerUndo("Edit Model") { target in
                target.saveEditableDetails(previous, projectID: projectID)
            }
            reconcileSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    func openSourceURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "Please enter a valid http or https link."
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
                errorMessage = "A tag with this name already exists."
                return false
            }
            try database.createTag(normalized)
            reloadTags()
            registerUndo("Add Tag") { target in target.deleteTag(normalized) }
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
            registerUndo("Rename Tag") { target in
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
            registerUndo("Delete Tag") { target in target.restoreTag(snapshot) }
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
        panel.title = "Choose Cover Image"
        panel.prompt = "Set Cover"
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
        if selectedProjectIDs.count > 1, selectedProjectIDs.contains(project.id) {
            projectsPendingDeletion = selectedProjects
        } else {
            projectsPendingDeletion = [project]
        }
    }

    func requestDeleteSelectedProjects() {
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

    private func loadSavedLibrary() throws {
        guard let database, let saved = try database.mostRecentLibrary() else { return }
        library = saved
        projects = try database.projects(libraryID: saved.id)
        tags = try database.allTags(libraryID: saved.id)
        beginScan(url: URL(fileURLWithPath: saved.rootPath))
    }

    private func beginScan(url: URL) {
        isScanning = true
        scanMessage = "Scanning…"
        Task { await scan(url: url) }
    }

    private func scan(url: URL) async {
        guard let database else { return }
        isScanning = true
        scanMessage = "Scanning…"
        defer { isScanning = false }

        do {
            let result = try await LibraryScanner.scan(rootURL: url)
            let savedLibrary = try await Task.detached(priority: .userInitiated) {
                try database.applyScan(result, rootURL: url)
            }.value
            library = savedLibrary
            projects = try database.projects(libraryID: savedLibrary.id)
            tags = try database.allTags(libraryID: savedLibrary.id)
            undoManager.removeAllActions()
            undoRevision &+= 1
            scanMessage = "\(projects.count) models · \(String(format: "%.1f", result.duration))s"
            reconcileSelection()
        } catch {
            errorMessage = error.localizedDescription
            scanMessage = "Scan failed"
        }
    }

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

    private func reconcileSelection() {
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
            registerUndo(favorite ? "Add Favorite" : "Remove Favorite") { target in
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
            registerUndo(assigned ? "Add Tag" : "Remove Tag") { target in
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
            registerUndo("Reorder Tags") { target in
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
            registerUndo("Delete Tag") { target in target.deleteTag(snapshot.name) }
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
            registerUndo(projectIDs.count == 1 ? "Delete Model" : "Delete Models") { target in
                target.restoreTrashedProjects(projectIDs: projectIDs, moves: moves)
            }
        } catch {
            rollbackTrashMoves(moves)
            errorMessage = "Could not move the model to Trash: \(error.localizedDescription)"
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
            registerUndo(projectIDs.count == 1 ? "Delete Model" : "Delete Models") { target in
                let restoredProjects = target.projects.filter { projectIDs.contains($0.id) }
                target.trashProjects(restoredProjects)
            }
        } catch {
            for move in restoredMoves.reversed() {
                try? FileManager.default.moveItem(at: move.originalURL, to: move.trashURL)
            }
            errorMessage = "Could not restore the model from Trash: \(error.localizedDescription)"
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
            registerUndo("Change Cover") { target in
                target.setCoverPath(previous, projectID: projectID)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
