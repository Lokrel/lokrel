import Sparkle
import SwiftUI

@main
struct LokrelApp: App {
    @StateObject private var appModel: AppModel
    private let updaterController: SPUStandardUpdaterController

    init() {
#if DEBUG
        if CommandLine.arguments.contains("--validate-localization") {
            do { try LocalizationValidation.run(); exit(EXIT_SUCCESS) }
            catch { print("Localization validation failed: \(error)"); exit(EXIT_FAILURE) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--validate-nas"), CommandLine.arguments.indices.contains(index + 1) {
            Task { @MainActor in
                do { try await RoundThreeValidation.nasRefresh(parent: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(EXIT_SUCCESS) }
                catch { print("NAS validation failed: \(error)"); exit(EXIT_FAILURE) }
            }
            RunLoop.main.run()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--validate-samples"), CommandLine.arguments.indices.contains(index + 1) {
            do { try RoundThreeValidation.samples(URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(EXIT_SUCCESS) }
            catch { print("Sample validation failed: \(error)"); exit(EXIT_FAILURE) }
        }
        if CommandLine.arguments.contains("--validate-refresh") {
            Task { @MainActor in
                do { try await RoundThreeValidation.refresh(); exit(EXIT_SUCCESS) }
                catch { print("Refresh validation failed: \(error)"); exit(EXIT_FAILURE) }
            }
            RunLoop.main.run()
        }
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
        if CommandLine.arguments.contains("--benchmark-refresh") {
            do { try RoundThreeValidation.benchmark(); exit(EXIT_SUCCESS) }
            catch { print("Incremental benchmark failed: \(error)"); exit(EXIT_FAILURE) }
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
#if DEBUG
        let testArgument = CommandLine.arguments.firstIndex(of: "--ui-test-library").flatMap { index in
            CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
        }
        if let testPath = testArgument ?? Bundle.main.object(forInfoDictionaryKey: "LokrelAcceptanceLibrary") as? String {
            let root = URL(fileURLWithPath: testPath)
            let path = root.appendingPathComponent("ui-test.sqlite").path
            let initialRoot = FileManager.default.fileExists(atPath: path) ? nil : root
            _appModel = StateObject(wrappedValue: AppModel(databasePath: path, initialLibraryURL: initialRoot))
        } else {
            _appModel = StateObject(wrappedValue: AppModel())
        }
#else
        _appModel = StateObject(wrappedValue: AppModel())
#endif
    }

    var body: some Scene {
        WindowGroup("lokrel") {
            ContentView(appModel: appModel)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(Self.initialWindowSize)
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
                Button(L10n.text("Choose Library…")) { appModel.chooseLibrary() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button(L10n.text("Refresh Library")) { appModel.refreshLibrary() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(appModel.library == nil || appModel.isScanning || appModel.isRefreshing)
                Button(L10n.text("Rescan Library")) { appModel.rescan() }
                    .disabled(appModel.library == nil || appModel.isScanning)
            }
            CommandMenu(L10n.text("Model")) {
                Button(L10n.text("Manage Tags…")) { appModel.isShowingTagManager = true }

                Divider()

                ForEach(Array(appModel.tags.prefix(9).enumerated()), id: \.element) { index, tag in
                    Button(L10n.format("Set Tag %ld: %@", index + 1, tag)) {
                        appModel.assignTagShortcut(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                    .disabled(!appModel.hasSelection)
                }

                Divider()

                Button(L10n.text("Move Selected Models to Trash")) {
                    appModel.requestDeleteSelectedProjects()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!appModel.hasSelection)
            }
        }
    }

    private static var initialWindowSize: CGSize {
#if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "LokrelAcceptanceCompactWindow") as? Bool == true {
            return CGSize(width: 980, height: 620)
        }
#endif
        return CGSize(width: 1320, height: 820)
    }
}
