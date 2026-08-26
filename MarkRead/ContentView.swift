import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var app: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $app.splitVisibility) {
            Sidebar(app: app)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            Detail(app: app)
        }
        .navigationTitle(app.document?.displayName ?? "MarkRead")
        .alert(item: $app.alert) { alert in
            switch alert.kind {
            case .message:
                return Alert(title: Text(alert.title), message: Text(alert.detail),
                             dismissButton: .default(Text("OK")))
            case .saveConflict:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.detail),
                    primaryButton: .destructive(Text("Overwrite")) { app.saveOverwriting() },
                    secondaryButton: .cancel(Text("Reload")) { app.reloadFromDisk() }
                )
            case .confirmOpen(let url):
                // The whole target is in `detail`, which is the point: this is a
                // scheme the app does not know, in a note the user may not have
                // written.
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.detail),
                    primaryButton: .default(Text("Open")) { NSWorkspace.shared.open(url) },
                    secondaryButton: .cancel()
                )
            case .encodingChange:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.detail),
                    primaryButton: .default(Text("Save as UTF-8")) { app.saveAsUTF8() },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if app.folder.root != nil {
                // A plain field rather than `.searchable(placement: .sidebar)`:
                // that modifier renders as an unstyled white slab inside a
                // NavigationSplitView sidebar on this OS. Only visible in a real
                // screenshot of the running app — it looks fine in a preview.
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(.tertiary)
                    TextField("Filter notes", text: filterText)
                        .textFieldStyle(.plain)
                    if !app.folder.filter.isEmpty {
                        Button {
                            app.folder.filter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            if app.folder.root == nil {
                withoutFolder
            } else {
                List(selection: selection) {
                    ForEach(app.folder.filtered) { entry in
                        row(entry)
                            .tag(entry.url)
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if app.folder.isScanning {
                        ProgressView().controlSize(.small)
                    } else if app.folder.filtered.isEmpty {
                        ContentUnavailableView("No notes", systemImage: "doc.text",
                                               description: Text("Nothing matching in this folder."))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let root = app.folder.root {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(root.lastPathComponent).lineLimit(1).truncationMode(.head)
                    if app.folder.truncated {
                        Image(systemName: "exclamationmark.triangle")
                            .help("This folder goes deeper or holds more notes than the list shows.")
                    }
                    Spacer()
                    Button {
                        app.chooseFolder()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose a different folder")
                    Button {
                        app.closeFolder()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Close this folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    /// No folder chosen: the note that is open, and the ones opened before it.
    ///
    /// This is not "nothing to show". Opening a single note used to index that
    /// note's own directory, which on a Desktop meant 114 files out of two
    /// unrelated vaults, flat, with no way to close the folder again. The list
    /// of recent documents was already being written to disk with nowhere to
    /// appear; here is where it appears.
    @ViewBuilder
    private var withoutFolder: some View {
        if app.document == nil, app.recents.isEmpty {
            ContentUnavailableView {
                Label("No notes yet", systemImage: "doc.text")
            } description: {
                Text("Open a note, or choose a folder to list one.")
            } actions: {
                Button("Open…") { app.openPanel() }
                Button("Choose Folder…") { app.chooseFolder() }
            }
        } else {
            List(selection: selection) {
                if let document = app.document {
                    Section("Open") {
                        Text(document.displayName)
                            .lineLimit(1)
                            .tag(document.url)
                    }
                }
                let earlier = app.recents.filter { $0 != app.document?.url }
                if !earlier.isEmpty {
                    Section("Recent") {
                        ForEach(earlier, id: \.self) { url in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .lineLimit(1)
                                Text((url.deletingLastPathComponent().path as NSString)
                                    .abbreviatingWithTildeInPath)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .padding(.vertical, 1)
                            .tag(url)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// `folder` is a `let` on AppState, so `$app.folder.filter` has nothing to
    /// project through — the binding is written out by hand instead.
    private var filterText: Binding<String> {
        Binding(get: { app.folder.filter }, set: { app.folder.filter = $0 })
    }

    /// Selecting a row opens that note; the binding writes straight through to
    /// the open document so there is no second source of truth for "which file".
    private var selection: Binding<URL?> {
        Binding(
            get: { app.document?.url },
            set: { if let url = $0, url != app.document?.url { app.openFile(url) } }
        )
    }

    @ViewBuilder
    private func row(_ entry: FolderIndex.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.name)
                .lineLimit(1)
            if !entry.parent.isEmpty {
                Text(entry.parent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Detail

private struct Detail: View {
    @Bindable var app: AppState

    var body: some View {
        if let document = app.document {
            editor(document)
        } else {
            ContentUnavailableView {
                Label("No file open", systemImage: "doc.richtext")
            } description: {
                Text("Open a Markdown file, or pick one from a folder.")
            } actions: {
                Button("Open…") { app.openPanel() }
                    .keyboardShortcut("o")
            }
            // A note dropped on the window with nothing open yet. The editor
            // handles the same drop once a document is on screen.
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                app.open(first)
                return true
            }
        }
    }

    private func editor(_ document: MarkdownDocument) -> some View {
        MarkdownEditor(
            text: Bindable(document).text,
            handle: app.editor,
            onLinkClick: { app.follow($0) },
            onLinkHover: { app.hoverLink($0) },
            onFileDrop: { app.open($0) }
        )
        // Where a link goes, before it is clicked. Sits over the text rather
        // than under it: a bar that appears and disappears in the layout would
        // shift the line the reader is on.
        .overlay(alignment: .bottomLeading) {
            if let target = app.hoveredLink {
                Text(target)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.bar, in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            // Nothing in the middle of the toolbar: the window title on the left
            // already says which file this is, and a second copy of the name in a
            // pill next to it said it twice.
            //
            // No sidebar button here either — NavigationSplitView already puts one
            // in the toolbar, and a second one sat next to it doing nothing.
            //
            // Unsaved changes still show: the Save button below is enabled only
            // when there is something to save.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.save()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(!document.isDirty)
                .help("Save (⌘S)")
            }
        }
    }
}
