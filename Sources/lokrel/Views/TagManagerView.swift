import SwiftUI

struct TagManagerView: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""
    @State private var tagPendingDeletion: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage Tags").font(.title2.bold())
                    Text("Tag order defines shortcuts 1–9.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            List {
                ForEach(Array(appModel.tags.enumerated()), id: \.element) { index, tag in
                    TagManagerRow(
                        tag: tag,
                        shortcut: index < 9 ? index + 1 : nil,
                        canMoveUp: index > 0,
                        canMoveDown: index < appModel.tags.count - 1,
                        appModel: appModel,
                        onDelete: { tagPendingDeletion = tag }
                    )
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                TextField("New tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                Button("Add") { addTag() }
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 470, height: 480)
        .confirmationDialog(
            "Delete Tag?",
            isPresented: Binding(
                get: { tagPendingDeletion != nil },
                set: { if !$0 { tagPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Tag", role: .destructive) {
                if let tagPendingDeletion { appModel.deleteTag(tagPendingDeletion) }
                tagPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { tagPendingDeletion = nil }
        } message: {
            Text("This tag will be removed from every model. You can undo this with Command-Z.")
        }
    }

    private func addTag() {
        if appModel.createTag(newTag) { newTag = "" }
    }
}

private struct TagManagerRow: View {
    let tag: String
    let shortcut: Int?
    let canMoveUp: Bool
    let canMoveDown: Bool
    @ObservedObject var appModel: AppModel
    let onDelete: () -> Void
    @State private var editedName: String

    init(
        tag: String,
        shortcut: Int?,
        canMoveUp: Bool,
        canMoveDown: Bool,
        appModel: AppModel,
        onDelete: @escaping () -> Void
    ) {
        self.tag = tag
        self.shortcut = shortcut
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.appModel = appModel
        self.onDelete = onDelete
        _editedName = State(initialValue: tag)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(shortcut.map(String.init) ?? "—")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            TextField("Tag name", text: $editedName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveName)

            Button(action: saveName) {
                Image(systemName: "checkmark")
            }
            .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || editedName == tag)
            .help("Save Name")

            Button { appModel.moveTag(tag, offset: -1) } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!canMoveUp)
            .help("Move Up")

            Button { appModel.moveTag(tag, offset: 1) } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(!canMoveDown)
            .help("Move Down")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .help("Delete Tag")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
    }

    private func saveName() {
        appModel.renameTag(tag, to: editedName)
    }
}
