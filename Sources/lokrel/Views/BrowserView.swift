import AppKit
import SwiftUI

struct BrowserView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Group {
            if appModel.library == nil {
                ContentUnavailableView {
                    Label(L10n.text("Create a Model Library"), systemImage: "shippingbox")
                } description: {
                    Text(L10n.text("Choose the folder that contains your 3D model collection."))
                } actions: {
                    Button(L10n.text("Choose Folder…")) { appModel.chooseLibrary() }
                        .buttonStyle(.borderedProminent)
                }
            } else if appModel.projects.isEmpty && appModel.isScanning {
                ProgressView(L10n.text("Scanning model library…"))
            } else if appModel.filteredProjects.isEmpty {
                if appModel.activeFilterCount > 0 {
                    ContentUnavailableView(
                        L10n.text("No Matching Models"),
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(L10n.text("Try removing one or more filters."))
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let hint = appModel.dragHint {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(hint).font(.caption)
                        Spacer()
                        Button { appModel.dragHint = nil } label: { Image(systemName: "xmark") }
                    }.padding(10).background(.regularMaterial)
                }
                BrowserStatusBar(appModel: appModel)
            }
        }
        .navigationTitle(browserTitle)
        .searchable(text: $appModel.searchText, prompt: L10n.text("Search models, files, and tags"))
        .toolbar {
            ToolbarItemGroup {
                if appModel.isScanning {
                    ProgressView().controlSize(.small)
                }
                Picker(L10n.text("Layout"), selection: $appModel.layout) {
                    Label(L10n.text("Grid"), systemImage: "square.grid.2x2").tag(BrowserLayout.grid)
                    Label(L10n.text("List"), systemImage: "list.bullet").tag(BrowserLayout.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                Menu {
                    Picker(L10n.text("Sort By"), selection: $appModel.sortOrder) {
                        ForEach(BrowserSort.allCases) { order in Text(order.title).tag(order) }
                    }.pickerStyle(.inline)
                    Divider()
                    Picker(L10n.text("Direction"), selection: $appModel.sortAscending) {
                        Text(L10n.text("Ascending")).tag(true)
                        Text(L10n.text("Descending")).tag(false)
                    }.pickerStyle(.inline)
                } label: {
                    Label(appModel.sortOrder.title, systemImage: "arrow.up.arrow.down").labelStyle(.titleAndIcon)
                }
                .help(L10n.format("Sort by %@", appModel.sortOrder.title))
                .accessibilityLabel(L10n.text("Sort Models"))
            }
        }
    }

    private var browserTitle: String {
        switch appModel.selectedSection {
        case .all: return L10n.text("All Models")
        case .favorites: return L10n.text("Favorites")
        case .recent: return L10n.text("Recent")
        case let .tag(name): return name
        case let .folder(path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }
}

private struct ProjectGridView: View {
    @ObservedObject var appModel: AppModel
    @State private var frames: [String: CGRect] = [:]

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, Int((geometry.size.width - 36 + 16) / (appModel.cardSize + 16)))
            let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(appModel.browserItems) { item in
                            ProjectCard(item: item, appModel: appModel)
                                .id(item.id)
                                .background(GeometryReader { card in
                                    Color.clear.preference(key: CardFrames.self,
                                        value: [item.id: card.frame(in: .named("models"))])
                                })
                        }
                    }
                    .padding(18)
                }
                .coordinateSpace(name: "models")
                .onPreferenceChange(CardFrames.self) { frames = $0 }
                .background(BrowserInput(frames: frames, click: { id, event in
                    if let choice = ModelDragContent.fileChoice(id) {
                        if event.type == .leftMouseDown { appModel.selectModelFile(projectID: choice.projectID, fileID: choice.fileID) }
                        return
                    }
                    let modified = !event.modifierFlags.intersection([.command, .shift]).isEmpty
                    let alreadyMultiSelected = appModel.selectedProjectIDs.count > 1 && appModel.selectedProjectIDs.contains(id)
                    if event.type == .leftMouseDown {
                        if alreadyMultiSelected && !modified { appModel.focusedProjectID = id }
                        else { appModel.selectProject(id, extending: event.modifierFlags.contains(.command), range: event.modifierFlags.contains(.shift)) }
                        if event.clickCount == 2, let project = appModel.projects.first(where: { $0.id == id }) { appModel.openPrimaryFile(project) }
                    } else if alreadyMultiSelected && !modified {
                        appModel.selectProject(id, extending: false)
                    }
                }, key: { event in
                    if event.keyCode == 49 { appModel.togglePreview(); return true }
                    if [123, 124, 125, 126].contains(event.keyCode), !event.modifierFlags.contains(.command) {
                        appModel.navigate(key: event.keyCode, columns: count, extending: event.modifierFlags.contains(.shift))
                        return true
                    }
                    if event.keyCode == 0, event.modifierFlags.contains(.command) {
                        appModel.selectedProjectIDs = Set(appModel.browserItems.map(\.id)); return true
                    }
                    return false
                }, drag: { appModel.prepareDrag($0) }))
                .onChange(of: appModel.focusedProjectID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }
}

private struct ProjectCard: View {
    let item: BrowserItem
    var project: ModelProject { item.project }
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                ProjectThumbnail(project: project, appModel: appModel)
                    .frame(maxWidth: .infinity)
                    .frame(height: appModel.cardSize * 0.78)
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
                    .help(project.favorite ? L10n.text("Remove from Favorites") : L10n.text("Add to Favorites"))
                }
                .padding(8)
            }

            Text(project.displayName)
                .font(.headline)
                .lineLimit(1)
            HStack {
                Text(project.modelTypes)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                if let group = item.group {
                    Button {
                        appModel.toggleGroup(group.id)
                    } label: {
                        Label("\(group.projects.count)", systemImage: appModel.showAllModels || appModel.expandedSourceGroups.contains(group.id)
                              ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(appModel.showAllModels)
                    .help(L10n.text("Expand or collapse source group"))
                    .accessibilityLabel(L10n.format("Source group, %ld projects", group.projects.count))
                } else if item.isGroupMember {
                    Image(systemName: "link").foregroundStyle(.secondary)
                }
            }
            .frame(height: 20)
            HStack {
                Text(project.modifiedAt?.formatted(date: appModel.cardSize < 170 ? .numeric : .abbreviated, time: .omitted) ?? "—")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: project.size, countStyle: .file))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if project.files.filter(\.isPrimaryModel).count > 1 {
                Divider().padding(.top, 3)
                ProjectModelFiles(project: project, appModel: appModel)
            }
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
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(appModel.selectedProjectIDs.contains(project.id)
                              ? Color.accentColor.opacity(0.45)
                              : Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.displayName)
        .accessibilityAction { appModel.selectProject(project.id, extending: false) }
        .contextMenu { ProjectContextMenu(project: project, appModel: appModel) }
    }
}

private struct ProjectListView: View {
    @ObservedObject var appModel: AppModel
    @State private var frames: [String: CGRect] = [:]

    var body: some View {
        Table(appModel.browserItems, selection: $appModel.selectedProjectIDs) {
            TableColumn(L10n.text("Name")) { item in
                let project = item.project
                VStack(alignment: .leading) {
                HStack(spacing: 10) {
                    ProjectThumbnail(project: project, appModel: appModel)
                        .frame(width: 46, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if let group = item.group {
                        Button { appModel.toggleGroup(group.id) } label: {
                            Label("\(group.projects.count)", systemImage: appModel.showAllModels || appModel.expandedSourceGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.borderless).disabled(appModel.showAllModels)
                    }
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
                ProjectModelFiles(project: project, appModel: appModel)
                }
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: CardFrames.self, value: [project.id: geometry.frame(in: .named("models"))])
                })
            }
            .width(min: 180, ideal: 220)
            TableColumn(L10n.text("Modified")) { item in
                let project = item.project
                Text(project.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "—")
                    .lineLimit(1)
                    .help(project.modifiedAt?.formatted(date: .complete, time: .standard) ?? "—")
            }
            .width(min: 120, ideal: 135)
            TableColumn(L10n.text("Size")) { item in
                let project = item.project
                Text(ByteCountFormatter.string(fromByteCount: project.size, countStyle: .file))
            }
            .width(70)
            TableColumn(L10n.text("Type")) { item in
                Text(item.project.modelTypes)
            }
            .width(min: 50, ideal: 55)
        }
        .coordinateSpace(name: "models")
        .onPreferenceChange(CardFrames.self) { frames = $0 }
        .background(BrowserInput(frames: frames, click: { _, _ in }, key: { _ in false }, drag: { appModel.prepareDrag($0) }, handlesSelection: false))
        .onKeyPress(.space) { appModel.togglePreview(); return .handled }
    }
}

struct ProjectContextMenu: View {
    let project: ModelProject
    @ObservedObject var appModel: AppModel

    private var targetProjectIDs: Set<String> {
        appModel.actionProjectIDs(for: project.id)
    }

    private func destinationMenu(copy: Bool) -> some View {
        Menu(copy ? L10n.text("Copy To") : L10n.text("Move To")) {
            Text(L10n.text("Recent Folders"))
            if appModel.recentDestinations.isEmpty {
                Text(L10n.text("No recent folders"))
            }
            ForEach(appModel.recentDestinations, id: \.self) { path in
                let url = URL(fileURLWithPath: path)
                Button(url.lastPathComponent) { appModel.requestTransfer(project, copy: copy, destination: url) }
                    .help(path)
            }
            Divider()
            Button(L10n.text("Choose Folder…")) { appModel.requestTransfer(project, copy: copy) }
        }.disabled(appModel.isScanning || appModel.isTransferring)
    }

    var body: some View {
        Button(L10n.text("Open")) { appModel.openPrimaryFile(project) }
        Button(L10n.text("Show in Finder")) { appModel.revealInFinder(project) }
        Button(L10n.text("File Information…")) { appModel.informationProject = project }
        Divider()
        Button(L10n.text("New Folder…")) { appModel.folderCreationProject = project }
            .disabled(appModel.isScanning || appModel.isTransferring)
        destinationMenu(copy: false)
        destinationMenu(copy: true)
        Divider()
        Button(project.favorite ? L10n.text("Remove from Favorites") : L10n.text("Add to Favorites")) {
            appModel.toggleFavorite(projectID: project.id)
        }
        Menu(L10n.text("Tags")) {
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
        Menu(L10n.text("Set Cover Image")) {
            ForEach(project.files.filter(\.isImage)) { file in
                Button(file.filename) {
                    appModel.useAssociatedImage(file, projectID: project.id)
                }
            }
            if project.files.contains(where: \.isImage) { Divider() }
            Button(L10n.text("Choose Image…")) { appModel.chooseCustomCover(projectID: project.id) }
            if project.coverOverridePath != nil {
                Button(L10n.text("Use Automatic Cover")) { appModel.resetCover(projectID: project.id) }
            }
        }
        Divider()
        Button(L10n.text("Move to Trash"), role: .destructive) {
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
        .help(project.tags.isEmpty ? L10n.text("Set Tags") : project.tags.joined(separator: ", "))
    }
}
