import AppKit
import SwiftUI

/// The whole of the app's preferences: the face notes are read in, and how big
/// it is. `MarkdownStyle.bodySize` was a `static var` nobody ever assigned to —
/// seven reads and no writes — so there was nothing to change and nowhere to
/// change it from.
///
/// The values live in `UserDefaults` under `MarkdownStyle.Appearance`'s keys;
/// this view only writes them and tells the open editor to re-measure.
struct SettingsView: View {

    @AppStorage(MarkdownStyle.Appearance.sizeKey)
    private var size: Double = MarkdownStyle.Appearance.defaultSize
    /// Empty means the system font, which is also what an uninstalled family
    /// falls back to.
    @AppStorage(MarkdownStyle.Appearance.familyKey)
    private var family: String = ""
    @AppStorage(MarkdownStyle.Appearance.lookKey)
    private var look: String = MarkdownStyle.Look.markRead.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Look:", selection: $look) {
                    ForEach(MarkdownStyle.Look.allCases) { option in
                        Text(option.name).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Text(MarkdownStyle.Look(rawValue: look)?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("A Markdown file stores no appearance of its own — every program invents one. Pick the one you want this program to invent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Text font:", selection: $family) {
                    Text("System").tag("")
                    Divider()
                    // The system's own list, in the system's own order. A curated
                    // set here would be a second opinion about which fonts exist.
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                LabeledContent("Text size:") {
                    HStack(spacing: 10) {
                        Slider(value: $size, in: MarkdownStyle.Appearance.sizeRange, step: 1)
                        Text("\(Int(size)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Code, tables and front matter stay monospaced: a table shown as raw markdown is hand-aligned text, and hand-aligned columns only line up in a fixed-pitch face.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restore Defaults") {
                    family = ""
                    size = MarkdownStyle.Appearance.defaultSize
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        // One reload for either setting: it re-reads both and posts the change.
        .onChange(of: look) { MarkdownStyle.Appearance.reload() }
        .onChange(of: size) { MarkdownStyle.Appearance.reload() }
        .onChange(of: family) { MarkdownStyle.Appearance.reload() }
    }
}
