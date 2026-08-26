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
                // NavigationSplitView sidebar on this OS. Seen in a screenshot
                // taken through AppBridge, which is the only reason it was found
                // — it looks fine in a SwiftUI preview.
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
                ContentUnavailableView {
                    Label("No folder", systemImage: "folder")
                } description: {
                    Text("Choose a folder to list its notes.")
                } actions: {
                    Button("Choose Folder…") { app.chooseFolder() }
                }
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
                    Spacer()
                    Button {
                        app.chooseFolder()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose a different folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }
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
        }
    }

    private func editor(_ document: MarkdownDocument) -> some View {
        MarkdownEditor(
            text: Bindable(document).text,
            handle: app.editor,
            onLinkClick: { app.follow($0) }
        )
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
