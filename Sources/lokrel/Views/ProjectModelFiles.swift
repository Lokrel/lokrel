import SwiftUI

struct ProjectModelFiles: View {
    let project: ModelProject
    @ObservedObject var appModel: AppModel

    var body: some View {
        let files = project.files.filter(\.isPrimaryModel)
        if files.count > 1 {
            DisclosureGroup(isExpanded: Binding(
                get: { appModel.expandedProjectFiles.contains(project.id) },
                set: { if $0 { appModel.expandedProjectFiles.insert(project.id) } else { appModel.expandedProjectFiles.remove(project.id) } }
            )) {
                ForEach(files) { file in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text(file.filename).lineLimit(2)
                        Spacer(minLength: 0)
                        Text(file.displayType).fontWeight(.semibold)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(appModel.previewFileID == file.id ? Color.accentColor.opacity(0.16) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { appModel.selectModelFile(projectID: project.id, fileID: file.id) }
                    .help(L10n.text("Drag this file to your slicer. Select it and press Space to preview."))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: CardFrames.self, value: [ModelDragContent.fileKey(projectID: project.id, fileID: file.id): geometry.frame(in: .named("models"))])
                    })
                }
            } label: {
                Text(L10n.format("Model Files (%ld)", files.count)).font(.caption)
            }
        }
    }
}
