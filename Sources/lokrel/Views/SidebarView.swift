import SwiftUI

struct SidebarView: View {
    @ObservedObject var appModel: AppModel
    @State private var foldersExpanded = true
    @State private var tagsExpanded = true
    @State private var importDateExpanded = false
    @State private var fileTypesExpanded = true

    var body: some View {
        List {
            Section(L10n.text("Library")) {
                SidebarButton(
                    title: L10n.text("All Models"),
                    systemImage: "square.grid.2x2",
                    count: appModel.projects.count,
                    selected: appModel.selectedSection == .all
                ) { appModel.selectedSection = .all }

                SidebarButton(
                    title: L10n.text("Favorites"),
                    systemImage: "star",
                    count: appModel.projects.filter(\.favorite).count,
                    selected: appModel.selectedSection == .favorites
                ) { appModel.selectedSection = .favorites }

                SidebarButton(
                    title: L10n.text("Recent"),
                    systemImage: "clock",
                    selected: appModel.selectedSection == .recent
                ) { appModel.selectedSection = .recent }
            }

            if let tree = appModel.directoryTree {
                Section {
                    if foldersExpanded {
                        DirectoryRow(node: tree, appModel: appModel, isRoot: true)
                        OutlineGroup(tree.children, children: \.optionalChildren) { node in
                            DirectoryRow(node: node, appModel: appModel, isRoot: false)
                        }
                    }
                } header: {
                    CollapsibleSectionHeader(title: L10n.text("Folders"), isExpanded: $foldersExpanded)
                }
            }

            Section {
                if tagsExpanded {
                    ForEach(appModel.tags, id: \.self) { tag in
                        TagSidebarRow(tag: tag, appModel: appModel)
                    }
                }
            } header: {
                HStack {
                    CollapsibleSectionHeader(title: L10n.text("Tags"), isExpanded: $tagsExpanded)
                    Spacer()
                    Button {
                        appModel.isShowingTagManager = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Manage Tags"))
                }
            }

            Section {
                SidebarFilters(
                    appModel: appModel,
                    importDateExpanded: $importDateExpanded,
                    fileTypesExpanded: $fileTypesExpanded
                )
            } header: {
                HStack {
                    Text(appModel.activeFilterCount == 0
                         ? L10n.text("Filters")
                         : L10n.format("Filters (%ld)", appModel.activeFilterCount))
                    Spacer()
                    Button(L10n.text("Clear")) { appModel.clearFilters() }
                        .buttonStyle(.plain)
                        .disabled(appModel.activeFilterCount == 0)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                if let library = appModel.library {
                    Text(library.name)
                        .font(.caption)
                        .lineLimit(1)
                    Text(appModel.scanMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(L10n.text("Refresh Library")) { appModel.refreshLibrary() }
                    Button(L10n.text("Rescan Library")) { appModel.rescan() }
                        .buttonStyle(.borderless)
                        .disabled(appModel.isScanning)
                }
                Menu(appModel.library == nil ? L10n.text("Libraries") : L10n.text("Change Library")) {
                    ForEach(appModel.libraries) { library in
                        Button {
                            appModel.openLibrary(URL(fileURLWithPath: library.rootPath))
                        } label: {
                            Text("\(library.name)\n\(library.rootPath)")
                        }
                    }
                    Divider()
                    Button(L10n.text("Add Library…")) { appModel.chooseLibrary() }
                    Button(L10n.text("Manage Libraries…")) { appModel.isShowingLibraryManager = true }
                }
                .menuStyle(.borderlessButton)
                .disabled(appModel.isScanning || appModel.isTransferring)
            }
            .padding(12)
            .background(.bar)
        }
    }
}

private struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarFilters: View {
    @ObservedObject var appModel: AppModel
    @Binding var importDateExpanded: Bool
    @Binding var fileTypesExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Tags"))
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(appModel.tags, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(
                        get: { appModel.filterTags.contains(tag) },
                        set: { appModel.setFilterTag(tag, enabled: $0) }
                    ))
                    .toggleStyle(.checkbox)
                }
                Toggle(L10n.text("Untagged"), isOn: Binding(
                    get: { appModel.filterUntagged },
                    set: { appModel.setFilterUntagged($0) }
                ))
                .toggleStyle(.checkbox)
                Toggle(L10n.text("Match All"), isOn: $appModel.matchAllFilterTags)
                    .toggleStyle(.checkbox)
                    .disabled(appModel.filterTags.count < 2 || appModel.filterUntagged)
            }

            DisclosureGroup(L10n.text("Imported"), isExpanded: $importDateExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(ImportDateFilter.allCases) { option in
                        FilterChoiceRow(
                            title: option.title,
                            selected: appModel.importDateFilter == option
                        ) { appModel.importDateFilter = option }
                    }
                }
                .padding(.top, 7)
            }

            VStack(alignment: .leading, spacing: 7) {
                CollapsibleSectionHeader(title: L10n.text("File Types"), isExpanded: $fileTypesExpanded)
                if fileTypesExpanded {
                    ForEach(appModel.availableFileTypes, id: \.self) { fileType in
                        Toggle(fileType.uppercased(), isOn: Binding(
                            get: { appModel.filterFileTypes.contains(fileType) },
                            set: { appModel.setFilterFileType(fileType, enabled: $0) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Toggle(L10n.text("Favorites Only"), isOn: $appModel.favoritesOnly)
                .toggleStyle(.checkbox)
        }
        .padding(.vertical, 3)
    }
}

private struct FilterChoiceRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TagSidebarRow: View {
    let tag: String
    @ObservedObject var appModel: AppModel

    var body: some View {
        SidebarButton(
            title: tag,
            systemImage: "tag",
            selected: appModel.selectedSection == .tag(tag)
        ) { appModel.selectedSection = .tag(tag) }
        .dropDestination(for: String.self) { payloads, _ in
            appModel.assignTagFromDrop(tag, payloads: payloads)
        }
        .help(L10n.text("Drop selected models here to add this tag"))
    }
}

private struct DirectoryRow: View {
    let node: DirectoryNode
    @ObservedObject var appModel: AppModel
    let isRoot: Bool

    var body: some View {
        Button {
            appModel.selectedSection = isRoot ? .all : .folder(node.path)
        } label: {
            HStack {
                Label(node.name, systemImage: isRoot ? "externaldrive" : "folder")
                    .lineLimit(1)
                Spacer()
                if node.projectCount > 0 {
                    Text(node.projectCount.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contextMenu {
            Button(L10n.text("Show in Finder")) { appModel.revealDirectory(path: node.path) }
        }
    }

    private var isSelected: Bool {
        if isRoot { return appModel.selectedSection == .all }
        return appModel.selectedSection == .folder(node.path)
    }
}

private struct SidebarButton: View {
    let title: String
    let systemImage: String
    var count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let count {
                    Text(count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}
