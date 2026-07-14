import AppKit
import SwiftUI

struct InspectorView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        if appModel.selectedProjectIDs.count > 1 {
            MultiSelectionInspector(appModel: appModel)
        } else if let project = appModel.selectedProject {
            ProjectInspector(project: project, appModel: appModel)
                .id(project.id)
        } else {
            ContentUnavailableView(
                "No Model Selected",
                systemImage: "sidebar.right",
                description: Text("Select a model to inspect its files and metadata.")
            )
        }
    }
}

private struct ProjectInspector: View {
    let project: ModelProject
    @ObservedObject var appModel: AppModel
    @State private var note: String
    @State private var details: EditableModelDetails
    @State private var extractedMetadata: ExtractedModelMetadata?
    @State private var isLoadingMetadata = false

    init(project: ModelProject, appModel: AppModel) {
        self.project = project
        self.appModel = appModel
        _note = State(initialValue: project.note)
        _details = State(initialValue: EditableModelDetails(
            customName: project.customName ?? "",
            author: project.author,
            sourceURL: project.sourceURL,
            license: project.license,
            modelDescription: project.modelDescription
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: 230)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contextMenu { ProjectContextMenu(project: project, appModel: appModel) }

                HStack {
                    Button("Open") { appModel.openPrimaryFile(project) }
                        .buttonStyle(.borderedProminent)
                    Button("Show in Finder") { appModel.revealInFinder(project) }
                    Spacer()
                    Button {
                        appModel.toggleFavorite(projectID: project.id)
                    } label: {
                        Image(systemName: project.favorite ? "star.fill" : "star")
                            .foregroundStyle(project.favorite ? .yellow : .primary)
                    }
                    .help(project.favorite ? "Remove from Favorites" : "Add to Favorites")
                }

                InspectorSection("Model Information") {
                    EditableMetadataRow(label: "Name") {
                        TextField(project.name, text: $details.customName)
                    }
                    EditableMetadataRow(label: "Author") {
                        TextField("Unknown", text: $details.author)
                    }
                    EditableMetadataRow(label: "License") {
                        TextField("Not specified", text: $details.license)
                    }
                    Text("Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $details.modelDescription)
                        .font(.body)
                        .frame(minHeight: 72)
                        .padding(4)
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }

                InspectorSection("Source / Download") {
                    TextField("https://…", text: $details.sourceURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Open Link") { appModel.openSourceURL(details.sourceURL) }
                            .disabled(!hasValidSourceURL)
                        Spacer()
                        Button("Save Changes") {
                            appModel.saveEditableDetails(details, projectID: project.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(details == savedDetails)
                    }
                    Text("Saved in lokrel only. Original files are not changed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                InspectorSection("File Properties") {
                    MetadataRow(label: "Original Name", value: project.name)
                    MetadataRow(label: "Primary File", value: project.primaryFile?.filename ?? "—")
                    MetadataRow(label: "Formats", value: formats)
                    MetadataRow(label: "File Count", value: project.files.count.formatted())
                    MetadataRow(label: "Size", value: ByteCountFormatter.string(
                        fromByteCount: project.size,
                        countStyle: .file
                    ))
                    MetadataRow(label: "Created", value: formatted(project.createdAt))
                    MetadataRow(label: "Modified", value: formatted(project.modifiedAt))
                    MetadataRow(label: "Location", value: project.directoryPath)
                }

                if project.files.contains(where: { $0.fileExtension.lowercased() == "3mf" }) {
                    InspectorSection("3MF Metadata") {
                        if isLoadingMetadata {
                            ProgressView("Reading metadata…")
                                .controlSize(.small)
                        } else if let extractedMetadata, !extractedMetadata.entries.isEmpty {
                            ForEach(extractedMetadata.entries) { entry in
                                MetadataRow(label: displayLabel(entry.name), value: entry.value)
                            }
                        } else {
                            Text("No embedded metadata found.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                InspectorSection("Tags") {
                    TagSelectionPicker(projectIDs: [project.id], appModel: appModel)
                }

                InspectorSection("Notes") {
                    TextEditor(text: $note)
                        .font(.body)
                        .frame(minHeight: 90)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Spacer()
                        Button("Save Note") { appModel.saveNote(note, projectID: project.id) }
                            .disabled(note == project.note)
                    }
                }

                InspectorSection("Files") {
                    ForEach(project.files) { file in
                        HStack(spacing: 9) {
                            Image(systemName: file.isImage ? "photo" : "doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.filename).lineLimit(1)
                                Text("\(file.displayType) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let modifiedAt = file.modifiedAt {
                                    Text(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Inspector")
        .task(id: project.id) { await loadMetadata() }
    }

    private func formatted(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    private var savedDetails: EditableModelDetails {
        EditableModelDetails(
            customName: project.customName ?? "",
            author: project.author,
            sourceURL: project.sourceURL,
            license: project.license,
            modelDescription: project.modelDescription
        )
    }

    private var formats: String {
        Array(Set(project.files.map { $0.displayType })).sorted().joined(separator: ", ")
    }

    private var hasValidSourceURL: Bool {
        guard let url = URL(string: details.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    private func loadMetadata() async {
        guard project.files.contains(where: { $0.fileExtension.lowercased() == "3mf" }) else { return }
        isLoadingMetadata = true
        let metadata = await ThreeMFMetadataService.shared.metadata(for: project)
        extractedMetadata = metadata
        isLoadingMetadata = false
        guard let metadata else { return }
        if details.author.isEmpty { details.author = metadata.designer ?? "" }
        if details.license.isEmpty { details.license = metadata.license ?? "" }
        if details.modelDescription.isEmpty { details.modelDescription = metadata.description ?? "" }
        if details.sourceURL.isEmpty { details.sourceURL = metadata.sourceURL ?? "" }
    }

    private func displayLabel(_ name: String) -> String {
        let labels = [
            "DesignerUserId": "Designer User ID",
            "DesignModelId": "Design Model ID",
            "MakerLabFileId": "MakerLab File ID",
            "source_file": "Source File",
            "CreationDate": "Created",
            "ModificationDate": "Modified",
            "LicenseTerms": "License"
        ]
        return labels[name] ?? name
    }

    @ViewBuilder
    private var preview: some View {
        if let model = project.files.first(where: {
            ["stl", "obj"].contains($0.fileExtension.lowercased())
        }) {
            ModelPreviewView(fileURL: model.url)
        } else {
            ProjectThumbnail(project: project, appModel: appModel)
        }
    }
}

private struct MultiSelectionInspector: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ContentUnavailableView(
                "\(appModel.selectedProjectIDs.count) Models Selected",
                systemImage: "square.stack.3d.up",
                description: Text("Choose tags below or drag the selected models onto a tag in the sidebar.")
            )

            InspectorSection("Tags") {
                TagSelectionPicker(
                    projectIDs: appModel.selectedProjectIDs,
                    appModel: appModel
                )
            }

            HStack {
                Spacer()
                Button("Move to Trash", role: .destructive) {
                    appModel.requestDeleteSelectedProjects()
                }
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle("Inspector")
    }
}

private struct TagSelectionPicker: View {
    let projectIDs: Set<String>
    @ObservedObject var appModel: AppModel

    var body: some View {
        if appModel.tags.isEmpty {
            Text("No tags available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], alignment: .leading) {
                ForEach(appModel.tags, id: \.self) { tag in
                    let allSelected = appModel.tagIsAssignedToAll(tag, projectIDs: projectIDs)
                    let anySelected = appModel.tagIsAssignedToAny(tag, projectIDs: projectIDs)
                    Button {
                        appModel.toggleTag(tag, projectIDs: projectIDs)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: allSelected
                                  ? "checkmark.circle.fill"
                                  : anySelected ? "minus.circle.fill" : "circle")
                            Text(tag).lineLimit(1)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            allSelected || anySelected
                                ? Color.accentColor.opacity(0.18)
                                : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        Button("Manage Tags…") { appModel.isShowingTagManager = true }
            .buttonStyle(.link)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }
}

private struct EditableMetadataRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content
        }
    }
}
