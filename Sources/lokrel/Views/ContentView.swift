import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(appModel: appModel)
                .navigationSplitViewColumnWidth(min: 165, ideal: 190, max: 240)
        } content: {
            BrowserView(appModel: appModel)
                .navigationSplitViewColumnWidth(min: 480, ideal: 760)
        } detail: {
            InspectorView(appModel: appModel)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        }
        .alert("lokrel", isPresented: Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )) {
            Button("OK") { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "Unknown error")
        }
    }
}
