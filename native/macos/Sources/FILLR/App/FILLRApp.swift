import AppKit
import SwiftUI

@main
struct FILLRApp: App {
    @StateObject private var store = FillrStore()

    var body: some Scene {
        WindowGroup("FILLR") {
            ContentView(store: store)
                .frame(minWidth: 620, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Download Folder…") { store.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Refresh") { store.refresh() }
                    .keyboardShortcut("r")
                Button("Toggle Progress Overlay") { store.toggleOverlay() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}
