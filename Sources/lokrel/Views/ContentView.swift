import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(appModel: appModel)
                .disabled(appModel.isTransferring || appModel.isScanning)
                .navigationSplitViewColumnWidth(min: 165, ideal: 190, max: 240)
        } content: {
            BrowserView(appModel: appModel)
                .disabled(appModel.isTransferring || appModel.isScanning)
                .navigationSplitViewColumnWidth(min: 480, ideal: 760)
        } detail: {
            InspectorView(appModel: appModel)
                .disabled(appModel.isTransferring || appModel.isScanning)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        }
        .alert("lokrel", isPresented: Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )) {
            Button(L10n.text("OK")) { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? L10n.text("Unknown error"))
        }
        .confirmationDialog(
            appModel.projectsPendingDeletion.count == 1
                ? L10n.text("Move Model to Trash?")
                : L10n.format("Move %ld Models to Trash?", appModel.projectsPendingDeletion.count),
            isPresented: Binding(
                get: { !appModel.projectsPendingDeletion.isEmpty },
                set: { if !$0 { appModel.cancelDelete() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("Move to Trash"), role: .destructive) {
                appModel.movePendingProjectsToTrash()
            }
            Button(L10n.text("Cancel"), role: .cancel) { appModel.cancelDelete() }
        } message: {
            Text(L10n.text("All files associated with the selected models will be moved to the macOS Trash."))
        }
        .sheet(isPresented: Binding(
            get: { appModel.isShowingWelcome || appModel.isScanning || appModel.isShowingLibraryManager },
            set: { if !$0 && !appModel.isScanning { appModel.dismissWelcome(); appModel.isShowingLibraryManager = false } }
        ), onDismiss: { appModel.finishScanPresentation() }) {
            if appModel.isScanning || appModel.isShowingWelcome { LibraryScanDialog(appModel: appModel) }
            else { LibraryManagerDialog(appModel: appModel) }
        }
        .sheet(isPresented: Binding(
            get: { appModel.previewProjectID != nil },
            set: { if !$0 { appModel.previewProjectID = nil } }
        )) { CoverPreview(appModel: appModel) }
        .sheet(item: $appModel.informationProject) { project in
            ModelInformationDialog(projectID: project.id, appModel: appModel)
        }
        .sheet(item: $appModel.folderCreationProject) { project in
            NewFolderDialog(project: project, appModel: appModel)
        }
        .sheet(item: $appModel.transferRequest) { request in
            TransferDialog(request: request, appModel: appModel)
        }
        .sheet(item: $appModel.transferReport) { report in
            TransferReportDialog(report: report, appModel: appModel)
        }
        .alert(L10n.text("Organize Source Groups?"), isPresented: $appModel.showOrganizationPrompt) {
            Button(L10n.text("Review Plan…")) { appModel.reviewOrganization() }
            Button(L10n.text("Not Now"), role: .cancel) { appModel.dismissOrganizationPrompt() }
        } message: {
            Text(L10n.format("Found %ld source groups spread across different folders. Review a plan to bring each group into one folder. Virtual groups are already available.", appModel.organizationCandidates.count))
        }
        .sheet(isPresented: $appModel.isShowingTagManager) {
            TagManagerView(appModel: appModel)
        }
    }
}
