import SwiftUI

struct BrowserView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Group {
            if appModel.library == nil {
                ContentUnavailableView {
                    Label("Create a Model Library", systemImage: "shippingbox")
                } description: {
                    Text("Choose the folder that contains your 3D model collection.")
                } actions: {
                    Button("Choose Folder…") { appModel.chooseLibrary() }
                        .buttonStyle(.borderedProminent)
                }
            } else if appModel.projects.isEmpty && appModel.isScanning {
                ProgressView("Scanning model library…")
            } else if appModel.filteredProjects.isEmpty {
                ContentUnavailableView.search(text: appModel.searchText)
            } else if appModel.layout == .grid {
                ProjectGridView(appModel: appModel)
            } else {
                ProjectListView(appModel: appModel)
            }
        }
        .navigationTitle(browserTitle)
        .searchable(text: $appModel.searchText, prompt: "Search models, files, and tags")
        .toolbar {
            ToolbarItemGroup {
                if appModel.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    appModel.rescan()
                } label: {
                    Label("Rescan Library", systemImage: "arrow.clockwise")
                }
                .disabled(appModel.library == nil || appModel.isScanning)

                Picker("Layout", selection: $appModel.layout) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(BrowserLayout.grid)
                    Label("List", systemImage: "list.bullet").tag(BrowserLayout.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
            }
        }
    }

    private var browserTitle: String {
        switch appModel.selectedSection {
        case .all: return "All Models"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case let .tag(name): return name
        case let .folder(path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }
}

private struct ProjectGridView: View {
    @ObservedObject var appModel: AppModel
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(appModel.filteredProjects) { project in
                    ProjectCard(project: project, appModel: appModel)
                        .onTapGesture { appModel.selectedProjectID = project.id }
                }
            }
            .padding(18)
        }
    }
}

private struct ProjectCard: View {
    let project: ModelProject
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                ProjectThumbnail(project: project, appModel: appModel)
                    .frame(maxWidth: .infinity)
                    .frame(height: 148)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if project.favorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .padding(8)
                        .shadow(radius: 2)
                }
            }

            Text(project.displayName)
                .font(.headline)
                .lineLimit(1)
            HStack {
                Text(project.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: project.size, countStyle: .file))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(appModel.selectedProjectID == project.id
                      ? Color.accentColor.opacity(0.16)
                      : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .contextMenu { ProjectContextMenu(project: project, appModel: appModel) }
    }
}

private struct ProjectListView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Table(appModel.filteredProjects, selection: $appModel.selectedProjectID) {
            TableColumn("Name") { project in
                HStack(spacing: 10) {
                    ProjectThumbnail(project: project, appModel: appModel)
                        .frame(width: 46, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Image(systemName: project.favorite ? "star.fill" : "star")
                        .foregroundStyle(project.favorite ? Color.yellow : Color.secondary.opacity(0.45))
                    Text(project.displayName)
                }
                .contextMenu { ProjectContextMenu(project: project, appModel: appModel) }
            }
            TableColumn("Modified") { project in
                Text(project.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            }
            .width(min: 130, ideal: 160)
            TableColumn("Size") { project in
                Text(ByteCountFormatter.string(fromByteCount: project.size, countStyle: .file))
            }
            .width(90)
            TableColumn("Type") { project in
                Text(project.primaryFile?.displayType ?? "—")
            }
            .width(65)
        }
    }
}

struct ProjectContextMenu: View {
    let project: ModelProject
    @ObservedObject var appModel: AppModel

    var body: some View {
        Button("Open") { appModel.openPrimaryFile(project) }
        Button("Show in Finder") { appModel.revealInFinder(project) }
        Divider()
        Button(project.favorite ? "Remove from Favorites" : "Add to Favorites") {
            appModel.toggleFavorite(projectID: project.id)
        }
        Menu("Set Cover Image") {
            ForEach(project.files.filter(\.isImage)) { file in
                Button(file.filename) {
                    appModel.useAssociatedImage(file, projectID: project.id)
                }
            }
            if project.files.contains(where: \.isImage) { Divider() }
            Button("Choose Image…") { appModel.chooseCustomCover(projectID: project.id) }
            if project.coverOverridePath != nil {
                Button("Use Automatic Cover") { appModel.resetCover(projectID: project.id) }
            }
        }
    }
}
