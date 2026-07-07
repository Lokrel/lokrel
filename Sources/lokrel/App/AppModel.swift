import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var library: LibraryLocation?
    @Published private(set) var projects: [ModelProject] = []
    @Published private(set) var tags: [String] = []
    @Published var selectedProjectID: String?
    @Published var selectedSection: LibrarySection = .all
    @Published var layout: BrowserLayout = .grid
    @Published var searchText = ""
    @Published private(set) var isScanning = false
    @Published private(set) var scanMessage = ""
    @Published var errorMessage: String?

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

    var selectedProject: ModelProject? {
        projects.first(where: { $0.id == selectedProjectID })
    }

    var directoryTree: DirectoryNode? {
        guard let library else { return nil }
        return DirectoryNode.build(rootPath: library.rootPath, projects: projects)
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
                return project.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            case let .folder(path):
                return URL(fileURLWithPath: project.directoryPath).standardizedFileURL.path == path
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sectionProjects }
        return sectionProjects.filter { project in
            project.displayName.localizedCaseInsensitiveContains(query)
                || project.author.localizedCaseInsensitiveContains(query)
                || project.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || project.files.contains(where: {
                    $0.filename.localizedCaseInsensitiveContains(query)
                })
        }
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Choose Model Library"
        panel.prompt = "Choose Library"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await scan(url: url) }
    }

    func rescan() {
        guard let library else { return }
        Task { await scan(url: URL(fileURLWithPath: library.rootPath)) }
    }

    func toggleFavorite(projectID: String) {
        guard let database, let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let newValue = !projects[index].favorite
        do {
            try database.setFavorite(newValue, projectID: projectID)
            projects[index].favorite = newValue
        } catch { errorMessage = error.localizedDescription }
    }

    func saveNote(_ note: String, projectID: String) {
        guard let database, let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        do {
            try database.setNote(note, projectID: projectID)
            projects[index].note = note
        } catch { errorMessage = error.localizedDescription }
    }

    func saveEditableDetails(_ details: EditableModelDetails, projectID: String) {
        guard let database, let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        do {
            try database.setEditableDetails(details, projectID: projectID)
            let trimmedName = details.customName.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index].customName = trimmedName.isEmpty ? nil : trimmedName
            projects[index].author = details.author.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index].sourceURL = details.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index].license = details.license.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index].modelDescription = details.modelDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

    func addTag(_ name: String, projectID: String) {
        guard let database, let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        do {
            try database.addTag(normalized, projectID: projectID)
            if !projects[index].tags.contains(where: {
                $0.caseInsensitiveCompare(normalized) == .orderedSame
            }) {
                projects[index].tags.append(normalized)
                projects[index].tags.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            reloadTags()
        } catch { errorMessage = error.localizedDescription }
    }

    func removeTag(_ name: String, projectID: String) {
        guard let database, let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        do {
            try database.removeTag(name, projectID: projectID)
            projects[index].tags.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
            reloadTags()
        } catch { errorMessage = error.localizedDescription }
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

    private func loadSavedLibrary() throws {
        guard let database, let saved = try database.mostRecentLibrary() else { return }
        library = saved
        projects = try database.projects(libraryID: saved.id)
        tags = try database.allTags(libraryID: saved.id)
        if FileManager.default.fileExists(atPath: saved.rootPath) {
            Task { await scan(url: URL(fileURLWithPath: saved.rootPath)) }
        }
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
            scanMessage = "\(projects.count) models · \(String(format: "%.1f", result.duration))s"
            if let selectedProjectID,
               !projects.contains(where: { $0.id == selectedProjectID }) {
                self.selectedProjectID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            scanMessage = "Scan failed"
        }
    }

    private func reloadTags() {
        guard let database, let library else { return }
        do { tags = try database.allTags(libraryID: library.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func setCoverPath(_ path: String?, projectID: String) {
        guard let database, let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        do {
            try database.setCoverOverride(path: path, projectID: projectID)
            projects[index].coverOverridePath = path
        } catch { errorMessage = error.localizedDescription }
    }
}
