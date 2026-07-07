import SwiftUI

struct SidebarView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        List {
            Section("Library") {
                SidebarButton(
                    title: "All Models",
                    systemImage: "square.grid.2x2",
                    count: appModel.projects.count,
                    selected: appModel.selectedSection == .all
                ) { appModel.selectedSection = .all }

                SidebarButton(
                    title: "Favorites",
                    systemImage: "star",
                    count: appModel.projects.filter(\.favorite).count,
                    selected: appModel.selectedSection == .favorites
                ) { appModel.selectedSection = .favorites }

                SidebarButton(
                    title: "Recent",
                    systemImage: "clock",
                    selected: appModel.selectedSection == .recent
                ) { appModel.selectedSection = .recent }
            }

            if let tree = appModel.directoryTree {
                Section("Folders") {
                    DirectoryRow(node: tree, appModel: appModel, isRoot: true)
                    OutlineGroup(tree.children, children: \.optionalChildren) { node in
                        DirectoryRow(node: node, appModel: appModel, isRoot: false)
                    }
                }
            }

            if !appModel.tags.isEmpty {
                Section("Tags") {
                    ForEach(appModel.tags, id: \.self) { tag in
                        SidebarButton(
                            title: tag,
                            systemImage: "tag",
                            selected: appModel.selectedSection == .tag(tag)
                        ) { appModel.selectedSection = .tag(tag) }
                    }
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
                }
                Button(appModel.library == nil ? "Create Library" : "Change Library…") {
                    appModel.chooseLibrary()
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
            .background(.bar)
        }
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
            Button("Show in Finder") { appModel.revealDirectory(path: node.path) }
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
