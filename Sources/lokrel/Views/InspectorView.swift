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
                L10n.text("No Model Selected"),
                systemImage: "sidebar.right",
                description: Text(L10n.text("Select a model to inspect its files and metadata."))
            )
        }
    }
}

struct ProjectInspector: View {
    let informationOnly: Bool
    let project: ModelProject
    @ObservedObject var appModel: AppModel
    @State private var note: String
    @State private var details: EditableModelDetails
    @State private var extractedMetadata: ExtractedModelMetadata?
    @State private var isLoadingMetadata = false
    @State private var sourceInfo = ModelSourceInfo()

    init(project: ModelProject, appModel: AppModel, informationOnly: Bool = false) {
        self.informationOnly = informationOnly
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
                if !informationOnly {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: 230)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contextMenu { ProjectContextMenu(project: project, appModel: appModel) }

                HStack {
                    Button(L10n.text("Open")) { appModel.openPrimaryFile(project) }
                        .buttonStyle(.borderedProminent)
                    Button(L10n.text("Show in Finder")) { appModel.revealInFinder(project) }
                    Spacer()
                    Button {
                        appModel.toggleFavorite(projectID: project.id)
                    } label: {
                        Image(systemName: project.favorite ? "star.fill" : "star")
                            .foregroundStyle(project.favorite ? .yellow : .primary)
                    }
                    .help(project.favorite ? L10n.text("Remove from Favorites") : L10n.text("Add to Favorites"))
                }

                }

                InspectorSection(L10n.text("Model Information")) {
                    EditableMetadataRow(label: L10n.text("Name")) {
                        TextField(project.name, text: $details.customName)
                    }
                    EditableMetadataRow(label: L10n.text("Author")) {
                        TextField(L10n.text("Unknown"), text: $details.author)
                    }
                    EditableMetadataRow(label: L10n.text("License")) {
                        TextField(L10n.text("Not specified"), text: $details.license)
                    }
                    Text(L10n.text("Description"))
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

                InspectorSection(L10n.text("Source / Download")) {
                    if let detected = project.embeddedSourceURL, !detected.isEmpty, let destination = URL(string: detected) {
                        Text(L10n.text("Detected Model Page")).font(.caption).foregroundStyle(.secondary)
                        Link(detected, destination: destination)
                            .font(.caption).lineLimit(2).textSelection(.enabled)
                    } else {
                        Text(L10n.text("Model page not identified")).font(.caption).foregroundStyle(.secondary)
                    }
                    if !project.sourceIdentity.isEmpty && (project.embeddedSourceURL ?? "").isEmpty {
                        Text(L10n.text("Source identified for grouping. The file does not contain a public model-page address."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let platform = sourceInfo.platform ?? (project.sourceIdentity.isEmpty ? nil : "MakerWorld") {
                        MetadataRow(label: L10n.text("Website"), value: platform)
                    }
                    if let download = sourceInfo.downloadURL {
                        Button(L10n.text("Original Download")) { appModel.openSourceURL(download.absoluteString) }.buttonStyle(.link)
                        Text(L10n.text("Download links may expire.")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(L10n.text("Custom Model Page")).font(.caption).foregroundStyle(.secondary)
                    TextField("https://…", text: $details.sourceURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(L10n.text("Open Link")) { appModel.openSourceURL(details.sourceURL) }
                            .disabled(!hasValidSourceURL)
                        Spacer()
                        Button(L10n.text("Save Changes")) {
                            appModel.saveEditableDetails(details, projectID: project.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(details == savedDetails)
                    }
                    Text(L10n.text("Saved in lokrel only. Original files are not changed."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                InspectorSection(L10n.text("File Properties")) {
                    MetadataRow(label: L10n.text("Original Name"), value: project.name)
                    MetadataRow(label: L10n.text("Primary File"), value: project.primaryFile?.filename ?? "—")
                    MetadataRow(label: L10n.text("Formats"), value: formats)
                    MetadataRow(label: L10n.text("File Count"), value: project.files.count.formatted())
                    MetadataRow(label: L10n.text("Size"), value: ByteCountFormatter.string(
                        fromByteCount: project.size,
                        countStyle: .file
                    ))
                    MetadataRow(label: L10n.text("Created"), value: formatted(project.primaryFile?.createdAt))
                    MetadataRow(label: L10n.text("Modified"), value: formatted(project.modifiedAt))
                    MetadataRow(label: L10n.text("Location"), value: project.directoryPath)
                }

                if project.files.contains(where: { $0.fileExtension.lowercased() == "3mf" }) {
                    InspectorSection(L10n.text("3MF Metadata")) {
                        if isLoadingMetadata {
                            ProgressView(L10n.text("Reading metadata…"))
                                .controlSize(.small)
                        } else if let extractedMetadata, !extractedMetadata.entries.isEmpty {
                            ForEach(extractedMetadata.entries) { entry in
                                MetadataRow(label: displayLabel(entry.name), value: entry.value)
                            }
                        } else {
                            Text(L10n.text("No embedded metadata found."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                InspectorSection(L10n.text("Tags")) {
                    TagSelectionPicker(projectIDs: [project.id], appModel: appModel)
                }

                InspectorSection(L10n.text("Notes")) {
                    TextEditor(text: $note)
                        .font(.body)
                        .frame(minHeight: 90)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Spacer()
                        Button(L10n.text("Save Note")) { appModel.saveNote(note, projectID: project.id) }
                            .disabled(note == project.note)
                    }
                }

                InspectorSection(L10n.text("Files")) {
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
                        .onDrag { NSItemProvider(object: file.url as NSURL) }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(L10n.text("Inspector"))
        .task(id: project.id + project.sourceSignature) { await loadMetadata() }
        .onChange(of: savedDetails) { _, value in details = value }
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
        guard let file = project.primaryFile else { return }
        sourceInfo = await Task.detached(priority: .utility) {
            ModelSourceResolver.resolve(fileURL: file.url)
        }.value
        guard !Task.isCancelled else { return }
        isLoadingMetadata = true
        let metadata = await ThreeMFMetadataService.shared.metadata(for: project)
        guard !Task.isCancelled else { return }
        extractedMetadata = metadata
        isLoadingMetadata = false
        guard let metadata else { return }
        if details.author.isEmpty { details.author = metadata.designer ?? "" }
        if details.license.isEmpty { details.license = metadata.license ?? "" }
        if details.modelDescription.isEmpty { details.modelDescription = metadata.description ?? "" }

    }

    private func displayLabel(_ name: String) -> String {
        let labels = [
            "CopyRight": L10n.text("Copyright"),
            "DesignRegion": L10n.text("Design Region"),
            "DesignerCover": L10n.text("Designer Cover"),
            "DesignProfileId": L10n.text("Print Profile ID"),
            "ProfileCover": L10n.text("Print Profile Cover"),
            "ProfileTitle": L10n.text("Print Profile Title"),
            "ProfileUserId": L10n.text("Profile User ID"),
            "ProfileUserName": L10n.text("Profile User Name"),
            "Thumbnail_Middle": L10n.text("Medium Thumbnail"),
            "Thumbnail_Small": L10n.text("Small Thumbnail"),

            "Title": L10n.text("Title"),
            "Designer": L10n.text("Designer"),
            "dc:creator": L10n.text("Designer"),
            "Description": L10n.text("Description"),
            "Copyright": L10n.text("Copyright"),
            "License": L10n.text("License"),
            "Application": L10n.text("Application"),
            "Origin": L10n.text("Origin"),
            "DesignerUserId": L10n.text("Designer User ID"),
            "DesignModelId": L10n.text("Design Model ID"),
            "MakerLabFileId": L10n.text("MakerLab File ID"),
            "source_file": L10n.text("Source File"),
            "CreationDate": L10n.text("Created"),
            "ModificationDate": L10n.text("Modified"),
            "LicenseTerms": L10n.text("License")
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
                L10n.format("%ld Models Selected", appModel.selectedProjectIDs.count),
                systemImage: "square.stack.3d.up",
                description: Text(L10n.text("Choose tags below or drag the selected models onto a tag in the sidebar."))
            )

            InspectorSection(L10n.text("Tags")) {
                TagSelectionPicker(
                    projectIDs: appModel.selectedProjectIDs,
                    appModel: appModel
                )
            }

            HStack {
                Spacer()
                Button(L10n.text("Move to Trash"), role: .destructive) {
                    appModel.requestDeleteSelectedProjects()
                }
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle(L10n.text("Inspector"))
    }
}

private struct TagSelectionPicker: View {
    let projectIDs: Set<String>
    @ObservedObject var appModel: AppModel

    var body: some View {
        if appModel.tags.isEmpty {
            Text(L10n.text("No tags available."))
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

        Button(L10n.text("Manage Tags…")) { appModel.isShowingTagManager = true }
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
