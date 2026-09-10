import AppKit
import SwiftUI

func presentFilePanel(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
    let finish: (NSApplication.ModalResponse) -> Void = { response in
        panel.orderOut(nil)
        completion(response)
    }
    if var window = NSApp.keyWindow ?? NSApp.mainWindow {
        while let sheet = window.attachedSheet { window = sheet }
        panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
        panel.begin(completionHandler: finish)
    }
}

func chooseDestination(_ current: URL, completion: @escaping (URL?) -> Void) {
    let panel = NSOpenPanel()
    panel.title = L10n.text("Choose Destination Folder")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.showsHiddenFiles = current.pathComponents.contains { $0.hasPrefix(".") && $0 != "." }
    panel.directoryURL = current
    panel.prompt = L10n.text("Choose")
    presentFilePanel(panel) { response in
        completion(response == .OK ? panel.url : nil)
    }
}

struct NewFolderDialog: View {
    let project: ModelProject
    @ObservedObject var appModel: AppModel
    @State private var parent: URL
    @State private var name = ""
    @State private var error: String?
    init(project: ModelProject, appModel: AppModel) {
        self.project = project
        self.appModel = appModel
        _parent = State(initialValue: project.directoryURL)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("New Folder")).font(.title2)
            TextField(L10n.text("Folder name"), text: $name).textFieldStyle(.roundedBorder)
            Text(L10n.text("Location")).font(.headline)
            Text(parent.path).textSelection(.enabled)
            Button(L10n.text("Choose Location…")) { chooseDestination(parent) { if let url = $0 { parent = url } } }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { appModel.folderCreationProject = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Create Folder")) {
                    do { try appModel.createFolder(parent: parent, name: name) }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520)
    }
}

struct TransferDialog: View {
    let request: TransferRequest
    @ObservedObject var appModel: AppModel
    @State private var parent: URL
    @State private var selectedGroups: Set<String>
    @State private var plans: [ProjectTransfer] = []
    @State private var error: String?
    @State private var checked = false
    @State private var showDetails = false
    init(request: TransferRequest, appModel: AppModel) {
        self.request = request
        self.appModel = appModel
        _parent = State(initialValue: request.destination ?? (request.isOrganization
            ? URL(fileURLWithPath: appModel.library?.rootPath ?? NSHomeDirectory())
            : request.projects.first?.directoryURL ?? URL(fileURLWithPath: NSHomeDirectory())))
        _selectedGroups = State(initialValue: Set(request.groups.map(\.id)))
    }
    private var title: String { request.isOrganization ? L10n.text("Organize Source Groups") : request.copy ? L10n.text("Copy Projects") : L10n.text("Move Projects") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2)
            HStack {
                Text(parent.path).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button(L10n.text("Choose Destination…")) {
                    chooseDestination(parent) { if let url = $0 { parent = url; prepare() } }
                }
            }
            if request.isOrganization {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(request.groups) { group in
                            Toggle(group.name + " — " + L10n.format("%ld projects", group.projects.count) + ", " + L10n.format("%ld files", group.projects.reduce(0) { $0 + $1.files.count }), isOn: Binding(
                                get: { selectedGroups.contains(group.id) },
                                set: { enabled in
                                    if enabled { selectedGroups.insert(group.id) } else { selectedGroups.remove(group.id) }
                                    prepare()
                                }
                            ))
                        }
                    }
                }.frame(maxHeight: 110)
            }
            Text(request.copy
                 ? L10n.text("Copy the selected projects and all associated files to this folder. Original files stay in place.")
                 : L10n.text("Move the selected projects and all associated files to this folder. Successfully moved files will no longer be at their original locations."))
                .font(.caption).foregroundStyle(.secondary)
            if plans.contains(where: { $0.files.contains { $0.source.lastPathComponent != $0.destination.lastPathComponent } }) {
                Text(L10n.text("Some destination names will change to keep projects together and avoid replacing existing files. See File Details below."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if checked && plans.isEmpty && error == nil {
                Text(request.isOrganization
                     ? L10n.text("Select a source group or choose a different destination.")
                     : L10n.text("These projects are already in this folder. Choose a different destination."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.text("File Details"), isExpanded: $showDetails) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(plans) { plan in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(plan.project.displayName + " — " + L10n.format("%ld files", plan.files.count)).font(.headline)
                            ForEach(plan.files) { file in
                                Text("\(file.source.path)\n→ \(file.destination.path)")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text(L10n.format("%ld projects", plans.count) + " · " + L10n.format("%ld files", plans.reduce(0) { $0 + $1.files.count })).font(.caption)
                Spacer()
                Button(L10n.text("Cancel")) { appModel.transferRequest = nil }.keyboardShortcut(.cancelAction)
                Button(request.copy ? L10n.text("Confirm Copy") : L10n.text("Confirm Move")) {
                    do {
                        try ProjectTransferService.preflight(plans, parent: parent)
                        appModel.performTransfer(plans, copy: request.copy, parent: parent,
                                                 skipped: request.projects.filter { project in !plans.contains { $0.id == project.id } })
                    } catch { self.error = error.localizedDescription; checked = false }
                }.buttonStyle(.borderedProminent)
                    .disabled(!checked || plans.isEmpty || appModel.isScanning || appModel.isTransferring)
                if !checked { Button(L10n.text("Check Again")) { prepare() } }
            }
        }.padding(24).frame(width: 660)
            .onAppear { prepare() }
    }
    private func prepare() {
        checked = false
        error = nil
        do {
            plans = try ProjectTransferService.plan(request: request, parent: parent, selectedGroups: selectedGroups)
            try ProjectTransferService.preflight(plans, parent: parent)
            checked = true
        } catch { self.error = error.localizedDescription }
    }
}

struct TransferReportDialog: View {
    let report: TransferReport
    @ObservedObject var appModel: AppModel
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("File Operation Report")).font(.title2)
            ScrollView { Text(report.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(L10n.text("Open Destination")) { NSWorkspace.shared.open(report.destination) }
                Button(L10n.text("Save Report…")) {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "lokrel-report.txt"
                    panel.showsHiddenFiles = report.destination.pathComponents.contains { $0.hasPrefix(".") && $0 != "." }
                    panel.directoryURL = report.destination
                    presentFilePanel(panel) { response in
                        guard response == .OK, let url = panel.url else { return }
                        do { try report.text.write(to: url, atomically: true, encoding: .utf8) }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button(L10n.text("Done")) { appModel.transferReport = nil }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 760, height: 570)
    }
}
