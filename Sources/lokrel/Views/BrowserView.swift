import AppKit
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
                if appModel.activeFilterCount > 0 {
                    ContentUnavailableView(
                        "No Matching Models",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try removing one or more filters.")
                    )
                } else {
                    ContentUnavailableView.search(text: appModel.searchText)
                }
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
                        .draggable(appModel.dragPayload(for: project.id))
                        .onTapGesture(count: 2) {
                            appModel.selectProject(project.id, extending: false)
                            appModel.openPrimaryFile(project)
                        }
                        .onTapGesture {
                            appModel.selectProject(
                                project.id,
                                extending: NSEvent.modifierFlags.contains(.command)
                            )
                        }
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

                HStack(spacing: 6) {
                    ProjectTagMenu(project: project, appModel: appModel)
                    Button {
                        appModel.toggleFavorite(projectID: project.id)
                    } label: {
                        Image(systemName: project.favorite ? "star.fill" : "star")
                            .foregroundStyle(project.favorite ? .yellow : .secondary)
                            .frame(width: 25, height: 25)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(project.favorite ? "Remove from Favorites" : "Add to Favorites")
                }
                .padding(8)
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
                .fill(appModel.selectedProjectIDs.contains(project.id)
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
        Table(appModel.filteredProjects, selection: $appModel.selectedProjectIDs) {
            TableColumn("Name") { project in
                HStack(spacing: 10) {
                    ProjectThumbnail(project: project, appModel: appModel)
                        .frame(width: 46, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(project.displayName)
                    Spacer(minLength: 8)
                    ProjectTagMenu(project: project, appModel: appModel)
                    Button {
                        appModel.toggleFavorite(projectID: project.id)
                    } label: {
                        Image(systemName: project.favorite ? "star.fill" : "star")
                            .foregroundStyle(project.favorite ? Color.yellow : Color.secondary.opacity(0.55))
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { appModel.openPrimaryFile(project) }
                .contextMenu { ProjectContextMenu(project: project, appModel: appModel) }
                .draggable(appModel.dragPayload(for: project.id))
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

    private var targetProjectIDs: Set<String> {
        appModel.actionProjectIDs(for: project.id)
    }

    var body: some View {
        Button("Open") { appModel.openPrimaryFile(project) }
        Button("Show in Finder") { appModel.revealInFinder(project) }
        Divider()
        Button(project.favorite ? "Remove from Favorites" : "Add to Favorites") {
            appModel.toggleFavorite(projectID: project.id)
        }
        Menu("Tags") {
            ForEach(Array(appModel.tags.enumerated()), id: \.element) { index, tag in
                Button {
                    appModel.toggleTag(tag, projectIDs: targetProjectIDs)
                } label: {
                    if appModel.tagIsAssignedToAll(tag, projectIDs: targetProjectIDs) {
                        Label("\(tag)\(index < 9 ? "  (\(index + 1))" : "")", systemImage: "checkmark")
                    } else {
                        Text("\(tag)\(index < 9 ? "  (\(index + 1))" : "")")
                    }
                }
            }
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
        Divider()
        Button("Move to Trash", role: .destructive) {
            appModel.requestDelete(project)
        }
    }
}

private struct ProjectTagMenu: View {
    let project: ModelProject
    @ObservedObject var appModel: AppModel

    private var targetProjectIDs: Set<String> {
        appModel.actionProjectIDs(for: project.id)
    }

    var body: some View {
        Menu {
            ForEach(Array(appModel.tags.enumerated()), id: \.element) { index, tag in
                Button {
                    appModel.toggleTag(tag, projectIDs: targetProjectIDs)
                } label: {
                    if appModel.tagIsAssignedToAll(tag, projectIDs: targetProjectIDs) {
                        Label("\(tag)\(index < 9 ? "  (\(index + 1))" : "")", systemImage: "checkmark")
                    } else {
                        Text("\(tag)\(index < 9 ? "  (\(index + 1))" : "")")
                    }
                }
            }
        } label: {
            Image(systemName: project.tags.isEmpty ? "tag" : "tag.fill")
                .foregroundStyle(project.tags.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 25, height: 25)
                .background(.regularMaterial, in: Circle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(project.tags.isEmpty ? "Set Tags" : project.tags.joined(separator: ", "))
    }
}
