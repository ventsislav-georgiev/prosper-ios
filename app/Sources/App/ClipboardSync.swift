import Foundation
import CryptoKit
import UIKit
import UniformTypeIdentifiers
import os

/// #621: the keyboards' clipboard history both ways with the Mac's, history to history: never
/// either pasteboard. The app syncs, the extensions only fill the store: on coming to the
/// front, when a session connects, and after the app's own copy, while the Mac lists
/// "clipboard" (its "Sync clipboard history with iPhone", off by default) and "Sync with Mac"
/// here is on. A sync the app is switched away from gets iOS's ~30 s to go on (#705).
/// ponytail: no background sync and no timer until a reason appears.
///
/// Only what the store keeps moves: text up to `ClipboardHistory.textLimit`, images (pulled
/// whole, or at most `sideMax` on the long side once the Mac lists "clipboard_max_side" (#712),
/// sha256 checked, downsampled as the store does). Not the Mac's files, nor longer text.
/// Phone to Mac first, being small: every clip this phone kept not sent yet, text in batches,
/// each image on its own connection. Then Mac to phone, paging back from the last sync's newest
/// row (`since`), at most a store's `cap`; the clips land as the Mac's one by one, deduped by
/// content, and never go back. A cut run keeps what landed and resumes past it; `since` moves only
/// when a run gets to the end. Concealed and transient clips never reach the store, so never the
/// Mac. A failure is only logged; the next trigger tries again.
@MainActor
enum ClipboardSync {
    /// "Sync with Mac", in the App Group. On by default: the Mac's own toggle is the opt-in.
    static let key = "clipboard.syncWithMac"
    /// ponytail: an image row over this isn't pulled; the store keeps it at 1024 px anyway.
    static let imageMax = 16 << 20
    /// #712: the long side asked of the Mac, the store's own bound.
    static let sideMax = Int(ClipboardHistory.imageSide)
    /// The Mac's most rows per list and items per addClipboardHistory.
    static let page = 100
    /// ponytail: the most rows read in one sync; past it, older rows than these wait for none.
    static let rowsMax = 1000
    static let off = "clipboard sync is off"

    static func on(_ defaults: UserDefaults? = KeyboardSettings.store()) -> Bool {
        defaults?.object(forKey: key) as? Bool ?? true
    }

    /// What a Mac was sent and seen up to, per saved machine.
    struct State: Codable, Equatable {
        var since: String?
        var sent: [UUID] = []
        /// The rows past `since` a cut run already took or skipped, so the next skips them.
        var pulled: [String] = []
    }

    private static let log = Logger(subsystem: "eu.illegible.prosper", category: "clipboard")

    // MARK: Triggers

    /// The Mac to sync with: the session list's last handshake, while it listed "clipboard".
    /// `maxSide`: `sideMax` while it listed "clipboard_max_side" too (#712), else nil.
    private(set) static var mac: (transport: SessionTransport, machine: String, maxSide: Int?)?
    private(set) static var running = false
    private static var again = false
    /// The store synced. Settable for tests.
    static var history: () -> ClipboardHistory? = { ClipboardHistory.shared() }
    /// iOS's grace for a sync the app is switched away from. Settable for tests.
    static var beginBackground: (@escaping () -> Void) -> UIBackgroundTaskIdentifier = {
        UIApplication.shared.beginBackgroundTask(withName: "clipboard sync", expirationHandler: $0)
    }
    static var endBackground: (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    private static var background = UIBackgroundTaskIdentifier.invalid

    /// The handshake's ops: the Mac to sync with, or none; then a sync.
    static func offer(_ ops: Set<SessionVerb>, over t: SessionTransport, machine: String) {
        mac = ops.contains(.clipboard) ? (t, machine, ops.contains(.clipboardMaxSide) ? sideMax : nil) : nil
        _ = foreground
        kick()
    }

    private static let foreground: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { kick() }
    }

    /// A sync, unless one runs: then one more after it.
    static func kick() {
        guard mac != nil, on() else { return }
        guard !running else { again = true; return }
        running = true
        background = beginBackground { MainActor.assumeIsolated { endBackgroundTask() } }
        Task {
            repeat {
                again = false
                guard let mac, on(), let history = history() else { break }
                do { try await sync(over: mac.transport, machine: mac.machine, history: history, maxSide: mac.maxSide) } catch {
                    log.error("clipboard sync: \(error.localizedDescription, privacy: .public)")
                }
            } while again
            running = false
            endBackgroundTask()
        }
    }

    /// Once per begin: the run's end or iOS's expiry, whichever comes first.
    private static func endBackgroundTask() {
        guard background != .invalid else { return }
        endBackground(background)
        background = .invalid
    }

    // MARK: The sync

    static func sync(over t: SessionTransport, machine: String, history: ClipboardHistory, maxSide: Int? = nil,
                     defaults: UserDefaults? = KeyboardSettings.store()) async throws {
        guard on(defaults) else { return }
        let key = "clipboard.sync." + machine
        var state = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        func save() { defaults?.set(try? JSONEncoder().encode(state), forKey: key) }

        // Phone to Mac first: what this phone kept, not sent yet.
        let clips = history.clips
        state.sent = state.sent.filter(Set(clips.map(\.id)).contains)
        let mine = clips.filter { $0.source == nil && !state.sent.contains($0.id) }
        let texts = mine.compactMap { c in c.text.map { ClipboardText(id: c.id, date: c.date, text: $0) } }
        for start in stride(from: 0, to: texts.count, by: page) {
            state.sent += done(try await t.addClipboardHistory(Array(texts[start..<min(start + page, texts.count)])))
            save()
        }
        for clip in mine {
            guard let name = clip.image, let data = try? Data(contentsOf: history.url(name)) else { continue }
            let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
            do {
                state.sent += done(try await t.clipboardUpload(ClipboardUpload(id: clip.id, date: clip.date, data: data, mime: mime)))
                save()
            } catch TransportError.server(let m) where m != off {
                log.error("clipboard upload: \(m, privacy: .public)")   // again on the next trigger
            }
        }

        // Mac to phone: newest first until [] or a store's worth. Each clip lands as it comes and
        // its row is remembered, so a cut run keeps them and the next one goes on from there.
        var rows: [ClipboardRow] = []
        var wanted = 0
        while wanted < history.cap, rows.count < rowsMax {
            let got = try await t.clipboardList(limit: page, before: rows.last?.id, since: state.since)
            if got.isEmpty { break }
            rows += got
            wanted += got.filter { $0.source != "iPhone" && ($0.kind == "text" || $0.kind == "image") }.count
        }
        for row in rows where row.source != "iPhone" && !state.pulled.contains(row.id) {
            if let clip = try await pull(row, over: t, maxSide: maxSide, into: history) { history.merge([clip]) }
            state.pulled.append(row.id)
            save()
        }
        // The end: the newest row is the next `since`, so every row under it is done.
        if let newest = rows.first?.date { state.since = newest }
        state.pulled = []
        save()
    }

    /// Taken, or skipped for good: a known id or the same content (duplicate), too old, not
    /// takeable. A failed write or no room goes again next time.
    private static func done(_ sent: ClipboardSent) -> [UUID] {
        (sent.added + sent.skipped.filter { !["write_failed", "no_space"].contains($0.value) }.keys).compactMap(UUID.init(uuidString:))
    }

    /// `row` as a clip the store keeps, nil to skip it: text whole (pulled when the list cut it),
    /// an image pulled and downsampled; not a file. A refused pull skips the row, unless sync
    /// went off on the Mac: that throws, so its rows come next time. #712: with `maxSide` an
    /// image is pulled whatever its size, the Mac sending it smaller; a reply over `max` (one
    /// it couldn't re-encode) is a skip too, never a throw that stops every later sync there.
    private static func pull(_ row: ClipboardRow, over t: SessionTransport, maxSide: Int?,
                             into history: ClipboardHistory) async throws -> ClipboardHistory.Clip? {
        let date = ClipboardRow.date(row.date) ?? Date()
        func item(max: Int) async throws -> Data? {
            do {
                // The only pull: the Mac sends text and files whole whatever `maxSide` says.
                let (sha, data) = try await t.clipboardItem(id: row.id, max: max, maxSide: maxSide)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == sha.lowercased() else { log.error("clipboard pull: hash mismatch"); return nil }
                return data
            } catch TransportError.server(let m) where m != off {
                log.error("clipboard pull: \(m, privacy: .public)")
                return nil
            } catch TransportError.protocolError(let m) where m == ProsperTransport.itemTooLarge {
                log.error("clipboard pull: \(m, privacy: .public)")
                return nil
            }
        }
        switch row.kind {
        case "text":
            var text = row.text
            if text?.utf8.count != row.size {
                // UTF-8 is at most 3 bytes per UTF-16 unit: anything larger can't fit `textLimit`.
                guard row.size <= 3 * ClipboardHistory.textLimit, let data = try await item(max: 3 * ClipboardHistory.textLimit)
                else { return nil }
                text = String(data: data, encoding: .utf8)
            }
            guard let text, text.utf16.count <= ClipboardHistory.textLimit,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ClipboardHistory.Clip(text: text, date: date, source: ClipboardHistory.mac)
        case "image":
            // ponytail: decoded on the main actor; a big image hitches for a moment. Off it if that shows.
            guard row.size > 0, maxSide != nil || row.size <= imageMax, let data = try await item(max: imageMax),
                  let name = history.storeImage(data: data) else { return nil }
            return ClipboardHistory.Clip(image: name, date: date, source: ClipboardHistory.mac)
        default:
            return nil   // ponytail: the Mac's files aren't synced this round
        }
    }
}

extension ClipboardSync.State {
    /// A state saved before a field was added reads, keeping what it had.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        since = try c.decodeIfPresent(String.self, forKey: .since)
        sent = try c.decodeIfPresent([UUID].self, forKey: .sent) ?? []
        pulled = try c.decodeIfPresent([String].self, forKey: .pulled) ?? []
    }
}
