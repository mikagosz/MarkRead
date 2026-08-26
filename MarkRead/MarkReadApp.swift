import AppKit
import SwiftUI

@main
struct MarkReadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView(app: app)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 1000, height: 720)
        .commands { menus }

        // Settings, and with it the ⌘, the system puts in the app menu.
        Settings {
            SettingsView()
        }
    }

    @CommandsBuilder
    private var menus: some Commands {
        CommandGroup(replacing: .newItem) {
            // New used to be replaced outright by Open, so ⌘N did nothing at
            // all. The panel picks the name and the place, the file is created
            // empty, and from there it is an ordinary open.
            Button("New Note") { app.newNote() }
                .keyboardShortcut("n")

            Divider()

            Button("Open…") { app.openPanel() }
                .keyboardShortcut("o")
            Button("Open Folder…") { app.chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            // `FolderIndex.clear()` existed from the start and was called from
            // nowhere: a folder could be swapped for another one but never let
            // go of. Here is the way out of folder mode.
            Button("Close Folder") { app.closeFolder() }
                .disabled(app.folder.root == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.save() }
                .keyboardShortcut("s")
                .disabled(app.document?.isDirty != true)
            Button("Reload from Disk") { app.reloadFromDisk() }
                .disabled(app.document == nil)
        }

        CommandMenu("Format") {
            Button("Bold") { EditorActions.wrap("**", in: app.editor.textView) }
                .keyboardShortcut("b")
            Button("Italic") { EditorActions.wrap("*", in: app.editor.textView) }
                .keyboardShortcut("i")
            Button("Strikethrough") { EditorActions.wrap("~~", in: app.editor.textView) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Highlight") { EditorActions.wrap("==", in: app.editor.textView) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Inline Code") { EditorActions.wrap("`", in: app.editor.textView) }
                .keyboardShortcut("e", modifiers: [.command])

            Divider()

            Button("Heading 1") { EditorActions.heading(1, in: app.editor.textView) }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Heading 2") { EditorActions.heading(2, in: app.editor.textView) }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button("Heading 3") { EditorActions.heading(3, in: app.editor.textView) }
                .keyboardShortcut("3", modifiers: [.command, .control])
            Button("Body Text") { EditorActions.heading(0, in: app.editor.textView) }
                .keyboardShortcut("0", modifiers: [.command, .control])

            Divider()

            Button("Bulleted List") { EditorActions.bulletList(in: app.editor.textView) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Task") { EditorActions.task(in: app.editor.textView) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Block Quote") { EditorActions.quote(in: app.editor.textView) }
                .keyboardShortcut("'", modifiers: [.command, .shift])
            Button("Code Block") { EditorActions.codeBlock(in: app.editor.textView) }
                .keyboardShortcut("e", modifiers: [.command, .shift])

            Divider()

            Button("Link") { EditorActions.link(in: app.editor.textView) }
                .keyboardShortcut("k")
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Note List") { app.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}

/// AppKit still owns two things SwiftUI has no hook for: files handed over by
/// Finder, and the "last window closed" lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func application(_ application: NSApplication, open urls: [URL]) {
        // A double-click in Finder, a drop on the Dock icon, or `open -a`.
        guard let first = urls.first else { return }
        AppState.shared.open(first)
        // A second file is a folder-or-file ambiguity we do not guess at; opening
        // the first and listing the rest in the sidebar is the honest behaviour.
        if urls.count > 1 {
            AppState.shared.alert = AppState.Alert(
                title: "Opened one file",
                detail: "MarkRead opens one file at a time. \(first.lastPathComponent) is open; use the note list for the rest."
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let document = AppState.shared.document, document.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.displayName)?"
        alert.informativeText = "Your edits will be lost otherwise."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AppState.shared.save()
            return AppState.shared.document?.isDirty == true ? .terminateCancel : .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
