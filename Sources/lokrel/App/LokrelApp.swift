import SwiftUI

@main
struct LokrelApp: App {
    @StateObject private var appModel: AppModel

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
        _appModel = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("lokrel") {
            ContentView(appModel: appModel)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Library…") { appModel.chooseLibrary() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Rescan Library") { appModel.rescan() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(appModel.library == nil || appModel.isScanning)
            }
        }
    }
}
