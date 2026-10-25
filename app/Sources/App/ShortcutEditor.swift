import SwiftUI

/// Terminal text size, nudged from the shortcut editor sheet. Stored as a point
/// size; changing it reflows the grid (fewer/more cols+rows) and resizes the pty.
enum TerminalPrefs {
    static let sizeKey = "terminalFontSize"
    /// 10% below the original hard-coded 13 pt — more of the remote screen fits.
    static let defaultSize: CGFloat = 11.7
    static let range: ClosedRange<CGFloat> = 8...20
    static let step: CGFloat = 0.5

    static var fontSize: CGFloat {
        get {
            let v = CGFloat(UserDefaults.standard.double(forKey: sizeKey))
            return v > 0 ? clamp(v) : defaultSize
        }
        set {
            UserDefaults.standard.set(Double(clamp(newValue)), forKey: sizeKey)
            // Flush now. UserDefaults writes back on its own schedule, and the size is
            // typically changed and then the app is put away or force-quit within
            // seconds — exactly the window where an unflushed write is lost and the
            // terminal comes back at the default size next launch.
            UserDefaults.standard.synchronize()
        }
    }

    static func clamp(_ v: CGFloat) -> CGFloat { min(max(v, range.lowerBound), range.upperBound) }
}

/// Add / remove / reorder the shortcut-bar keys. Persists to the same defaults key the
/// bar reads (`Shortcuts.shared`), so the bar reloads with the new set when the sheet
/// closes, and the Prosper keyboard's toolbar in other apps when it next shows.
struct ShortcutEditor: View {
    @AppStorage(Shortcuts.storageKey, store: Shortcuts.shared()) private var raw = ""   // observe-only: triggers refresh
    @State private var keys: [ShortcutKey] = []
    @Environment(\.dismiss) private var dismiss

    /// Written through `TerminalPrefs` rather than @AppStorage so the clamp and the
    /// flush apply to the stepper too — one writer for the one stored size.
    @State private var fontSize = Double(TerminalPrefs.fontSize)

    var body: some View {
        NavigationStack {
            List {
                Section("Text size") {
                    Stepper(value: $fontSize,
                            in: Double(TerminalPrefs.range.lowerBound)...Double(TerminalPrefs.range.upperBound),
                            step: Double(TerminalPrefs.step)) {
                        Text("\(fontSize, specifier: "%.1f") pt").font(.body.monospaced())
                    }
                    Button("Reset text size") { fontSize = Double(TerminalPrefs.defaultSize) }
                }
                .onChange(of: fontSize) { v in TerminalPrefs.fontSize = CGFloat(v) }
                Section {
                    ForEach(keys) { k in
                        Text(k.label).font(.body.monospaced())
                            .deleteDisabled(k.id == Shortcuts.sendID)   // send is mandatory
                    }
                        .onMove { keys.move(fromOffsets: $0, toOffset: $1); persist() }
                        .onDelete { keys.remove(atOffsets: $0); persist() }
                } header: {
                    Text("Active (drag to reorder, swipe to remove)")
                } footer: {
                    // `Shortcuts.hostKey`: the keys a text field can't use stay off it.
                    Text("The Prosper keyboard's toolbar in other apps shows these too, except the terminal-only keys.")
                }
                let avail = Shortcuts.catalog.filter { c in !keys.contains { $0.id == c.id } }
                if !avail.isEmpty {
                    Section("Add") {
                        ForEach(avail) { c in
                            Button { keys.append(c); persist() } label: {
                                Label(c.label, systemImage: "plus.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Shortcut Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") { keys = Shortcuts.defaults; persist() }
                }
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { keys = Shortcuts.load() }
    }

    private func persist() { Shortcuts.save(keys) }
}
