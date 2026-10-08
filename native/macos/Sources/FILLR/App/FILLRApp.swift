import AppKit
import SwiftUI

@main
struct FILLRApp: App {
    @StateObject private var store = FillrStore()
    @StateObject private var updates = UpdateController()
    @NSApplicationDelegateAdaptor(FillrAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("FILLR") {
            ContentView(store: store)
                .frame(minWidth: 620, minHeight: 560)
                .onAppear { appDelegate.store = store; updates.start(store: store) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.check() }.disabled(store.updatesBlocked)
                Toggle("Automatically Check for Updates", isOn: $updates.automaticChecks)
            }
            CommandGroup(after: .newItem) {
                Button("Choose Download Folder…") { store.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Refresh") { store.refresh() }
                    .keyboardShortcut("r")
                Button("Toggle Progress Overlay") { store.toggleOverlay() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        Settings {
            MediaPreferencesView(store: store)
                .disabled(store.isBuilding)
                .onAppear { store.beginPreferencesEditing() }
                .onDisappear { store.endPreferencesEditing() }
        }
    }
}
