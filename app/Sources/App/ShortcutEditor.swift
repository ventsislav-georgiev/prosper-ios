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

/// Add / remove / reorder a key list (`Shortcuts.Bar`). Persists to the defaults key its
/// bar reads (`Shortcuts.shared`): the terminal's reloads when the sheet closes, the Prosper
/// keyboard's toolbar in other apps when it next shows. Both are pushed from Settings; the
/// terminal screen opens the terminal's as a sheet (`sheet`). The terminal's has the text
/// size; the toolbar's send can go.
struct ShortcutEditor: View {
    let bar: Shortcuts.Bar
    let sheet: Bool
    @AppStorage private var raw: String   // observe-only: triggers refresh
    @State private var keys: [ShortcutKey] = []
    @Environment(\.dismiss) private var dismiss

    /// Written through `TerminalPrefs` rather than @AppStorage so the clamp and the
    /// flush apply to the stepper too — one writer for the one stored size.
    @State private var fontSize = Double(TerminalPrefs.fontSize)

    init(bar: Shortcuts.Bar = .terminal, sheet: Bool = true) {
        self.bar = bar
        self.sheet = sheet
        _raw = AppStorage(wrappedValue: "", bar.storageKey, store: Shortcuts.shared())
    }

    var body: some View {
        if sheet {
            NavigationStack {
                list.toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { reset }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        } else {
            list.toolbar { ToolbarItem(placement: .navigationBarTrailing) { reset } }
        }
    }

    private var reset: some View { Button("Reset") { keys = bar.defaults; persist() } }

    private var list: some View {
        List {
            if bar == .terminal {
                Section("Text size") {
                    Stepper(value: $fontSize,
                            in: Double(TerminalPrefs.range.lowerBound)...Double(TerminalPrefs.range.upperBound),
                            step: Double(TerminalPrefs.step)) {
                        Text("\(fontSize, specifier: "%.1f") pt").font(.body.monospaced())
                    }
                    Button("Reset text size") { fontSize = Double(TerminalPrefs.defaultSize) }
                }
                .onChange(of: fontSize) { v in TerminalPrefs.fontSize = CGFloat(v) }
            }
            Section {
                ForEach(keys) { k in
                    Text(k.label).font(.body.monospaced())
                        .deleteDisabled(bar.sendMandatory && k.id == Shortcuts.sendID)
                }
                    .onMove { keys.move(fromOffsets: $0, toOffset: $1); persist() }
                    .onDelete { keys.remove(atOffsets: $0); persist() }
            } header: {
                Text("Active (drag to reorder, swipe to remove)")
            } footer: {
                Text(bar == .terminal
                     ? "The Prosper keyboard's toolbar in other apps has its own keys, in Settings."
                     : "Above the Prosper keyboard in other apps, at the toggle on its strip's leading edge. Paste needs Full Access.")
            }
            let avail = bar.catalog.filter { c in !keys.contains { $0.id == c.id } }
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
        .navigationTitle(bar == .terminal ? "Terminal Shortcut Keys" : "System Keyboard Toolbar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { EditButton() } }
        .onAppear { keys = bar.load() }
    }

    private func persist() { Shortcuts.save(keys, key: bar.storageKey) }
}
