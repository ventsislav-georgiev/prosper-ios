import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Share › Prosper sheet's state (#610): what was shared, the chosen Mac's sessions, and
/// a note in place of the list when there is no Mac, it can't be reached, or nothing usable
/// was shared.
@MainActor
final class ShareModel: ObservableObject {
    @Published var machines: [Machine]
    @Published var machine: UUID?
    @Published var sessions: [DchSession] = []
    @Published var selected: String?
    @Published var text: String?
    @Published var image: Data?
    /// Nothing shared was text, a link or an image.
    @Published var unusable = false
    /// Shown instead of the session list.
    @Published var note: String?
    @Published var loading = false
    /// Settable for tests: the live list, as the app's session list dials it.
    var list: (Machine) async throws -> [DchSession] = { try await connectFirstTransport($0.addresses).sessions }

    init(machines: [Machine] = ShareInbox.machines()) {
        self.machines = machines
        machine = machines.first { $0.id == ShareInbox.last?.machine }?.id ?? machines.first?.id
    }

    /// The item Send hands over: nil until a session is picked and there is something to send.
    var item: ShareItem? {
        guard let machine, let selected, text != nil || image != nil else { return nil }
        return ShareItem(target: ShareTarget(machine: machine, session: selected), text: text, image: image)
    }

    func load() async {
        guard let m = machines.first(where: { $0.id == machine }) else {
            note = "Add your Mac in Prosper first."
            return
        }
        loading = true
        defer { loading = false }
        do {
            sessions = try await list(m)
            selected = ShareInbox.preselect(sessions, on: m.id)
            note = sessions.isEmpty ? "No sessions on \(m.name)." : nil
        } catch {
            sessions = []
            if case TransportError.hostUnreachable = error { note = "Can't reach \(m.name) — check Tailscale." }
            else { note = error.localizedDescription }
        }
    }

    /// The first image, and every text and web link a line apart. A file is none of them.
    /// `fallback`, the extension item's own text, is used only when nothing else loaded (#610 QA).
    func load(_ providers: [NSItemProvider], fallback: String? = nil) async {
        var texts: [String] = []
        for p in providers {
            if image == nil, p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let data: Data? = await withCheckedContinuation { c in
                    _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in c.resume(returning: d) }
                }
                image = data.flatMap { ShareInbox.png($0) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await Self.object(p, URL.self), !url.isFileURL { texts.append(url.absoluteString) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.text.identifier), let s = await Self.text(p) {
                texts.append(s)
            }
        }
        if texts.isEmpty, image == nil, let fallback, !fallback.isEmpty { texts = [fallback] }
        text = texts.isEmpty ? nil : texts.joined(separator: "\n")
        unusable = text == nil && image == nil
    }

    /// Loads by type, not `loadObject(ofClass: String.self)`, which fails cross-process with 4864 (#610 QA).
    private static func text(_ p: NSItemProvider) async -> String? {
        let ids = p.registeredTypeIdentifiers.compactMap(UTType.init)
        guard let type = ids.first(where: { $0.conforms(to: .plainText) }) ?? ids.first(where: { $0.conforms(to: .text) })
        else { return nil }
        let item: NSSecureCoding? = await withCheckedContinuation { c in
            p.loadItem(forTypeIdentifier: type.identifier) { v, _ in c.resume(returning: v) }
        }
        switch item {
        case let s as String: return s
        case let a as NSAttributedString: return a.string
        // Raw bytes only for plain text: RTF or HTML data would paste its markup.
        case let d as Data where type.conforms(to: .plainText): return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    private static func object<T: _ObjectiveCBridgeable>(_ p: NSItemProvider, _ type: T.Type) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { c in _ = p.loadObject(ofClass: type) { v, _ in c.resume(returning: v) } }
    }
}

/// Share › Prosper: a session to paste into, a preview of what goes, and Send. Nothing runs:
/// the app pastes it at the session's prompt and the user presses Return there.
struct ShareSheet: View {
    @ObservedObject var model: ShareModel
    var send: (ShareItem) -> Void = { _ in }
    var cancel: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                Section {
                    preview
                } footer: {
                    Text("Pasted at the prompt, never run: press Return in Prosper.")
                }
                if model.machines.count > 1 {
                    Picker("Mac", selection: $model.machine) {
                        ForEach(model.machines) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if let note = model.note {
                    Section { Text(note).foregroundStyle(.secondary) }
                } else {
                    Section("Session") {
                        if model.loading && model.sessions.isEmpty { ProgressView() }
                        ForEach(model.sessions) { s in
                            Button { model.selected = s.name } label: {
                                HStack {
                                    SessionRow(session: s)
                                    if model.selected == s.name {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                            .accessibilityAddTraits(model.selected == s.name ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("Prosper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { model.item.map(send) }.disabled(model.item == nil)
                }
            }
            .task(id: model.machine) { await model.load() }
        }
    }

    @ViewBuilder private var preview: some View {
        if model.unusable {
            Text("Prosper takes text, links and images.").foregroundStyle(.secondary)
        }
        if let png = model.image, let image = UIImage(data: png) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Image")
        }
        if let text = model.text {
            Text(verbatim: text).font(.callout.monospaced()).lineLimit(6)
        }
    }
}
