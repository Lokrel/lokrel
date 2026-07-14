import Sparkle
import SwiftUI

@main
struct LokrelApp: App {
    @StateObject private var appModel: AppModel
    private let updaterController: SPUStandardUpdaterController

    init() {
#if DEBUG
        if CommandLine.arguments.contains("--validate") {
            do {
                try DevelopmentValidation.run()
                print("lokrel validation passed")
                exit(EXIT_SUCCESS)
            } catch {
                print("lokrel validation failed: \(error)")
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.contains("--benchmark") {
            do {
                try DevelopmentValidation.benchmark(projectCount: 5_000)
                exit(EXIT_SUCCESS)
            } catch {
                print("lokrel benchmark failed: \(error)")
                exit(EXIT_FAILURE)
            }
        }
#endif
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        _appModel = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("lokrel") {
            ContentView(appModel: appModel)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(appModel.undoMenuTitle) { appModel.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!appModel.canUndo)
                Button(appModel.redoMenuTitle) { appModel.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!appModel.canRedo)
            }
            CommandGroup(after: .newItem) {
                Button("Choose Library…") { appModel.chooseLibrary() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Rescan Library") { appModel.rescan() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(appModel.library == nil || appModel.isScanning)
            }
            CommandMenu("Model") {
                Button("Manage Tags…") { appModel.isShowingTagManager = true }

                Divider()

                ForEach(Array(appModel.tags.prefix(9).enumerated()), id: \.element) { index, tag in
                    Button("Set Tag \(index + 1): \(tag)") {
                        appModel.assignTagShortcut(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                    .disabled(!appModel.hasSelection)
                }

                Divider()

                Button("Move Selected Models to Trash") {
                    appModel.requestDeleteSelectedProjects()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!appModel.hasSelection)
            }
        }
    }
}
