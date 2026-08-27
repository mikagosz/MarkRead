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
        .toolbar {
            // Sits at this level, not in the detail view, so it is there when
            // nothing is open — which is exactly when a blank note is wanted.
            ToolbarItem(placement: .navigation) {
                Button {
                    app.newNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Note (⌘N)")
            }
        }
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
            if hasRows { filterField }
            if hasRows { list } else { nothingYet }
        }
        // Right-click on the empty part of the list. Without this, the only way
        // to the Open and Choose Folder commands was the File menu or the empty
        // state's two buttons — and the empty state is gone the moment there is
        // one note in the list.
        .contextMenu { listCommands }
        // Notes dropped anywhere on the sidebar are pinned to it. This is the
        // whole of "add a note to the list": there is no button for it, because
        // the gesture people already try is dragging the file in.
        .dropDestination(for: URL.self) { urls, _ in
            app.add(urls)
            return true
        }
        .safeAreaInset(edge: .bottom) { folderBar }
    }

    // MARK: - The three sections

    /// Notes pinned by hand: dropped on the sidebar, or handed over by Finder
    /// alongside the one that was opened. These never fall off the list.
    private var pinned: [URL] { app.library.pinned.filter(matches) }
    /// Notes opened lately, newest first, bounded by `NoteLibrary.recentsLimit`.
    private var recents: [URL] { app.library.recents.filter(matches) }
    private var folderEntries: [FolderIndex.Entry] { app.folder.matching(app.sidebarFilter) }

    private var hasRows: Bool {
        !app.library.pinned.isEmpty || !app.library.recents.isEmpty || app.folder.root != nil
    }

    @ViewBuilder
    private var list: some View {
        List(selection: selection) {
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned, id: \.self) { url in
                        noteRow(url)
                            .tag(url)
                            .contextMenu { pinnedMenu(url) }
                    }
                    .onMove { app.library.movePinned(from: $0, to: $1) }
                } header: {
                    header("Pinned", systemImage: "pin.fill")
                }
            }

            if !recents.isEmpty {
                Section {
                    ForEach(recents, id: \.self) { url in
                        noteRow(url)
                            .tag(url)
                            .contextMenu { recentMenu(url) }
                    }
                } header: {
                    header("Recent", systemImage: "clock")
                }
            }

            if let root = app.folder.root {
                Section {
                    ForEach(folderEntries) { entry in
                        folderRow(entry)
                            .tag(entry.url)
                            .contextMenu { folderMenu(entry.url) }
                    }
                    if folderEntries.isEmpty {
                        Text(app.folder.isScanning ? "Reading…" : "Nothing matching in this folder.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    // The folder is a *place*, not a handful of loose notes, and
                    // the request was that the two never read as one list: its
                    // own name, its own icon, and a rule above it.
                    header(root.lastPathComponent, systemImage: "folder.fill", ruled: true)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// A section title that can actually be told apart from the rows under it.
    ///
    /// `.listStyle(.sidebar)` draws a plain section header in the same weight as
    /// a note's own subtitle, which is what let the folder's contents and the
    /// pinned notes read as one long list.
    private func header(_ title: String, systemImage: String, ruled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if ruled {
                Divider().padding(.top, 4).padding(.bottom, 6)
            }
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func noteRow(_ url: URL) -> some View {
        let gone = app.library.isMissing(url)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                if gone {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.tertiary)
                        .help("Not where it was. A disk or a share may be offline — the row is kept either way.")
                }
            }
            // The folder's name, not its path. A pinned note usually lives in a
            // vault whose path is four levels of "Mobile Documents/iCloud~md~…"
            // before it says anything a person recognises, and the sidebar is
            // 240 pt wide. The whole path is one hover away.
            Text(url.deletingLastPathComponent().lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.vertical, 1)
        .opacity(gone ? 0.55 : 1)
        .help((url.path as NSString).abbreviatingWithTildeInPath)
    }

    @ViewBuilder
    private func folderRow(_ entry: FolderIndex.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .lineLimit(1)
                // A note that is also pinned appears twice — once at the top of
                // the sidebar and once in its folder, where the folder listing
                // has to stay complete or it is not a folder listing. The pin
                // says the two rows are the same note rather than two notes with
                // the same name.
                if app.library.isPinned(entry.url) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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

    // MARK: - Menus

    /// What the list itself can do, as opposed to what one row can do.
    ///
    /// Repeated at the bottom of every row's menu on purpose: a right-click that
    /// lands on a row and a right-click that lands between rows should not be
    /// the difference between being able to open a folder and not.
    @ViewBuilder
    private var listCommands: some View {
        Button("Open Note…") { app.openPanel() }
        Button("Choose Folder…") { app.chooseFolder() }
        if app.folder.root != nil {
            Button("Close Folder") { app.closeFolder() }
        }
        if !app.library.recents.isEmpty {
            Button("Clear Recent") { app.library.clearRecents() }
        }
    }

    @ViewBuilder
    private func pinnedMenu(_ url: URL) -> some View {
        Button("Remove from Sidebar") { app.unpin(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        listCommands
    }

    @ViewBuilder
    private func recentMenu(_ url: URL) -> some View {
        Button("Pin to Sidebar") { app.pin(url) }
        Button("Remove from Recent") { app.forget(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        listCommands
    }

    @ViewBuilder
    private func folderMenu(_ url: URL) -> some View {
        Button("Pin to Sidebar") { app.pin(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        listCommands
    }

    // MARK: - Chrome

    /// A plain field rather than `.searchable(placement: .sidebar)`: that
    /// modifier renders as an unstyled white slab inside a NavigationSplitView
    /// sidebar on this OS. Only visible in a real screenshot of the running app —
    /// it looks fine in a preview.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.tertiary)
            TextField("Filter notes", text: $app.sidebarFilter)
                .textFieldStyle(.plain)
            if !app.sidebarFilter.isEmpty {
                Button {
                    app.sidebarFilter = ""
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

    /// Nothing pinned, nothing opened before, no folder. Says what the sidebar
    /// is for, including the part that has no button — dropping a note on it.
    private var nothingYet: some View {
        ContentUnavailableView {
            Label("No notes yet", systemImage: "doc.text")
        } description: {
            Text("Drag notes here to keep them in the list, open one, or choose a folder.")
        } actions: {
            Button("Open…") { app.openPanel() }
            Button("Choose Folder…") { app.chooseFolder() }
        }
    }

    @ViewBuilder
    private var folderBar: some View {
        if let root = app.folder.root {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(root.lastPathComponent).lineLimit(1).truncationMode(.head)
                if app.folder.isScanning {
                    ProgressView().controlSize(.small)
                }
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

    /// Selecting a row opens that note; the binding writes straight through to
    /// the open document so there is no second source of truth for "which file".
    private var selection: Binding<URL?> {
        Binding(
            get: { app.document?.url },
            set: { if let url = $0, url != app.document?.url { app.openFile(url) } }
        )
    }

    private func matches(_ url: URL) -> Bool {
        let needle = app.sidebarFilter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return url.lastPathComponent.localizedCaseInsensitiveContains(needle)
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
