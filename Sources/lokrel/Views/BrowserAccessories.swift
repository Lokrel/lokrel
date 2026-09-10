import AppKit
import SwiftUI

struct BrowserStatusBar: View {
    @ObservedObject var appModel: AppModel
    private var summary: String {
        let selected = appModel.selectedProjects
        var parts = [L10n.format("%ld projects", appModel.filteredProjects.count), L10n.format("%ld selected", selected.count)]
        if !selected.isEmpty {
            let types = Set(selected.flatMap { $0.files.filter(\.isPrimaryModel).map(\.displayType) }).sorted()
            parts.append(types.joined(separator: " · "))
            parts.append(ByteCountFormatter.string(fromByteCount: selected.reduce(0) { $0 + $1.size }, countStyle: .file))
        }
        return parts.joined(separator: ", ")
    }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary).font(.caption).lineLimit(2).accessibilityIdentifier("browser-status")
                    if !appModel.refreshMessage.isEmpty && appModel.refreshMessage != L10n.text("Up to date") {
                        Text(appModel.refreshMessage).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if appModel.isTransferring || appModel.isRefreshing { ProgressView().controlSize(.small) }
                if !appModel.organizationCandidates.isEmpty {
                    Button { appModel.reviewOrganization() } label: { Image(systemName: "folder.badge.gearshape") }
                        .help(L10n.text("Organize source groups…"))
                        .disabled(appModel.isScanning || appModel.isTransferring)
                }
                Toggle(L10n.text("Show All Models"), isOn: $appModel.showAllModels)
                    .toggleStyle(.switch).controlSize(.mini)
                    .help(L10n.text("Show every project in source groups, within the current filters"))
                Button { appModel.cardSize = max(130, appModel.cardSize - 20) } label: { Image(systemName: "minus") }
                    .help(L10n.text("Smaller cards"))
                Slider(value: $appModel.cardSize, in: 130...320).frame(width: 90)
                    .accessibilityLabel(L10n.text("Model card size"))
                Button { appModel.cardSize = min(320, appModel.cardSize + 20) } label: { Image(systemName: "plus") }
                    .help(L10n.text("Larger cards"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.bar)
        }
    }
}

struct CoverPreview: View {
    @ObservedObject var appModel: AppModel
    @State private var zoom: CGFloat = 1
    @State private var viewportRevision = 0
    private var project: ModelProject? { appModel.projects.first { $0.id == appModel.previewProjectID } }
    private var previewFile: ModelFile? {
        project?.files.first { $0.id == appModel.previewFileID } ?? project?.primaryFile
    }
    private var isSTL: Bool { previewFile?.fileExtension.lowercased() == "stl" }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { appModel.previewProjectID = nil } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(project?.displayName ?? L10n.text("Preview")).font(.headline)
                Spacer()
                Text(previewFile?.displayType ?? "").foregroundStyle(.secondary)
            }
            if isSTL, let file = previewFile {
                ModelPreviewView(fileURL: file.url)
                    .id("\(file.path):\(viewportRevision)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let project {
                        ProjectThumbnail(project: project, appModel: appModel)
                            .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                            .id(project.id)
                    }
                }
            }
            }
            HStack {
                Button { appModel.navigatePreview(-1) } label: { Image(systemName: "chevron.left") }
                    .help(L10n.text("Previous model"))
                Button { appModel.navigatePreview(1) } label: { Image(systemName: "chevron.right") }
                    .help(L10n.text("Next model"))
                Spacer()
                Text(L10n.text("Space / Esc to close")).foregroundStyle(.secondary)
                Spacer()
                if isSTL {
                    Text(L10n.text("Drag to rotate · Scroll to zoom")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("Reset View")) { viewportRevision += 1 }
                } else {
                    Button(L10n.text("Fit")) { zoom = 1 }
                    Slider(value: $zoom, in: 1...4).frame(width: 120).accessibilityLabel(L10n.text("Preview zoom"))
                }
            }
        }
        .padding(18)
        .frame(width: 840, height: 630)
        .background(PreviewKeyboardInput { event in
            switch event.keyCode {
            case 49, 53: appModel.previewProjectID = nil
            case 123: appModel.navigatePreview(-1)
            case 124: appModel.navigatePreview(1)
            default: return false
            }
            return true
        })
        .onChange(of: appModel.previewProjectID) { _, _ in zoom = 1 }
    }
}

struct ModelInformationDialog: View {
    let projectID: String
    @ObservedObject var appModel: AppModel
    var body: some View {
        VStack {
            HStack {
                Text(L10n.text("Model Information")).font(.title2)
                Spacer()
                Button(L10n.text("Done")) { appModel.informationProject = nil }.keyboardShortcut(.cancelAction)
            }.padding()
            if let project = appModel.projects.first(where: { $0.id == projectID }) {
                ProjectInspector(project: project, appModel: appModel, informationOnly: true)
            }
        }.frame(width: 640, height: 700)
    }
}
