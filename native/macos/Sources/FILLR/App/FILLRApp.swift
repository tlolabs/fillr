import AppKit
import SwiftUI

@main
struct FILLRApp: App {
    @StateObject private var store = FillrStore()
    @StateObject private var updates = UpdateController()
    @AppStorage(WindowLayout.preferenceKey) private var layout = WindowLayout.compactPanel
    @State private var resizeRequestID = UUID()
    @NSApplicationDelegateAdaptor(FillrAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("FILLR") {
            ContentView(store: store, layout: layout)
                .frame(minWidth: layout.minimumSize.width, minHeight: layout.minimumSize.height)
                .background(LayoutWindowSizing(layout: layout, resizeRequestID: resizeRequestID))
                .onAppear {
                    appDelegate.store = store
                    updates.start(store: store)
                }
        }
        .defaultSize(width: layout.preferredSize.width, height: layout.preferredSize.height)
        .windowResizability(.contentMinSize)
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
                Button("Preview Icon Animation") { store.previewIconAnimation() }
                    .disabled(store.iconPreviewRunning)
                Menu("App Icon") {
                    Picker("App Icon", selection: Binding(get: { store.iconStyle }, set: { store.setIconStyle($0) })) {
                        ForEach(DockIconStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Button("Toggle Progress Overlay") { store.toggleOverlay() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(before: .windowArrangement) {
                Menu("Layout") {
                    ForEach(WindowLayout.allCases) { choice in
                        Toggle(choice.title, isOn: Binding(
                            get: { layout == choice },
                            set: { _ in
                                // A preset stays selected when chosen again;
                                // the explicit request reapplies its window size.
                                layout = choice
                                resizeRequestID = UUID()
                            }
                        ))
                    }
                }
                Divider()
            }
        }
        Settings {
            MediaPreferencesView(store: store)
                .disabled(store.isBuilding)
                .onAppear { store.beginPreferencesEditing() }
                .onDisappear { store.endPreferencesEditing() }
        }
        .windowResizability(.contentSize)
    }
}
