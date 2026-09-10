import SwiftUI

struct LibraryScanDialog: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if appModel.isScanning {
                Text(L10n.text("Scanning Models")).font(.title2)
                Text(appModel.scanningLibraryName).font(.headline)
                if let total = appModel.scanProgress.total, total > 0 {
                    ProgressView(value: Double(appModel.scanProgress.completed), total: Double(total))
                    Text(L10n.format("%@: %@ / %@", stage, appModel.scanProgress.completed.formatted(), L10n.format("%ld models", total)))
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text(L10n.format("%@ · %@", stage, L10n.format("%ld files found", appModel.scanProgress.completed)))
                }
                Text(appModel.scanProgress.filename.isEmpty ? L10n.text("Preparing library…") : appModel.scanProgress.filename)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(L10n.text("Please wait while lokrel scans your models. This window closes when scanning finishes."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("Welcome to lokrel")).font(.title2)
                Text(L10n.text("Choose the folder that contains your models to create your first library. Your model files stay in their original locations."))
                HStack {
                    Spacer()
                    Button(L10n.text("Choose Later")) { appModel.dismissWelcome() }.keyboardShortcut(.cancelAction)
                    Button(L10n.text("Choose Folder…")) { appModel.chooseLibrary() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(26).frame(width: 480, alignment: .leading)
        .interactiveDismissDisabled(appModel.isScanning)
    }

    private var stage: String {
        switch appModel.scanProgress.stage {
        case .discovering: return L10n.text("Finding files")
        case .reading: return L10n.text("Reading models")
        case .saving: return L10n.text("Saving library")
        }
    }
}

struct LibraryManagerDialog: View {
    @ObservedObject var appModel: AppModel
    @State private var removing: LibraryLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Manage Libraries")).font(.title2)
            Text(L10n.text("Switch instantly using the saved index. Changes are checked automatically. Use Refresh Library to check now."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(appModel.libraries) { library in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(library.name).font(.headline)
                                Text(library.rootPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button(appModel.library?.id == library.id ? L10n.text("Current") : L10n.text("Switch")) {
                                appModel.openLibrary(URL(fileURLWithPath: library.rootPath))
                                appModel.isShowingLibraryManager = false
                            }.disabled(appModel.library?.id == library.id)
                            Button(L10n.text("Remove…")) { removing = library }
                        }
                        Divider()
                    }
                    if appModel.libraries.isEmpty { Text(L10n.text("No libraries added.")).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button(L10n.text("Add Library…")) { appModel.chooseLibrary() }
                Spacer()
                Button(L10n.text("Done")) { appModel.isShowingLibraryManager = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 660, height: 430)
        .confirmationDialog(L10n.text("Remove Library from lokrel?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.text("Remove Library"), role: .destructive) {
                if let removing { appModel.removeLibrary(removing) }
                removing = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { removing = nil }
        } message: {
            Text(L10n.format("%@\nOnly the library list entry will be removed. No model files will be deleted or moved. Tags, notes and other saved information will be restored when you add this folder again.", removing?.rootPath ?? ""))
        }
    }
}
