import Foundation

/// A dch session as presented to the UI (PLAN §11). `name` is the real dch
/// session name (shared with standalone dch); `alias` is the optional display
/// label from dch's alias sidecar.
struct DchSession: Identifiable, Hashable {
    var name: String
    var alias: String?
    /// dch's agent state for the session — `working`, `idle`, `blocked` or `done`,
    /// resolved server-side from the session's rendered screen. Empty/nil when the
    /// Mac runs an older Prosper (no state in the list response).
    var state: String? = nil
    /// Live subagents on the session's Claude Code agent panel, as dch counts them.
    /// 0 when there are none, or the Mac's dch is too old to say.
    var agents: Int = 0
    var meta: SessionMeta? = nil     // PRs and tasks; nil draws the row as before
    var id: String { name }
    var title: String { alias ?? name }
}

/// Terminal byte streams for one attached session. Output is delivered in
/// arrival order, losslessly (PLAN §14.2 — the whole value prop). `input` and
/// `resize` flow back to the pty.
protocol TerminalStream: AnyObject {
    /// Async sequence of raw output bytes, in order, never dropped.
    var output: AsyncStream<ArraySlice<UInt8>> { get }
    /// True once the remote process exited (server sent the exit frame). Lets the
    /// reconnect loop tell a clean `exit` apart from a dropped link.
    var exited: Bool { get }
    /// Send keystrokes / pasted bytes to the pty. Returns false when the stream is
    /// already closed and did NOT take the bytes — the caller still owns them. True
    /// means handed to the transport; if the transport later finds they never reached
    /// the socket it hands them back through `onUnsent`.
    @discardableResult func send(_ bytes: ArraySlice<UInt8>) -> Bool
    /// Notify the pty of a new terminal size.
    func resize(cols: Int, rows: Int)
    /// Force the remote program to repaint (after a soft-keyboard relayout),
    /// without reattaching the socket.
    func requestRedraw()
    /// Ask the server for dch's own rendered screen (its VT mirror) and deliver it
    /// to `onScreen`. Unlike `requestRedraw` this needs nothing from the remote
    /// program: whatever dch has is authoritative, so the client can repaint from
    /// it even when the TUI refuses to redraw. Never fires when the session's
    /// master has no mirror (older dch).
    func requestSnapshot()
    /// Put an image on the CLIPBOARD OF THE MACHINE running the session, so the
    /// ctrl-V we send next pastes it. Claude Code reads its own machine's
    /// clipboard, and Universal Clipboard doesn't reliably carry phone images
    /// there, so the bytes travel with the request.
    /// Same contract as `send`.
    @discardableResult func putClipboard(_ image: Data) -> Bool
    /// Frames the transport accepted but could not hand to the socket (the send
    /// failed before reaching the kernel), in send order. Called before `output`
    /// finishes, on any thread.
    var onUnsent: ((Outbound) -> Void)? { get set }
    /// Sink for `requestSnapshot` replies — a full screen in ANSI, ready to feed.
    var onScreen: ((ArraySlice<UInt8>) -> Void)? { get set }
    /// Detach this client (session keeps running).
    func close()
}

/// One user-originated write, queued by `SessionConnection` while no stream can take it.
enum Outbound: Equatable {
    case bytes([UInt8])
    case clipboard(Data)
}

/// Pluggable transport so SSH and the Prosper-hosted dch-server both fit behind
/// one surface (PLAN §11). The app is written against this; the concrete
/// transport is chosen at connect time.
protocol SessionTransport: AnyObject {
    func listSessions() async throws -> [DchSession]
    /// Attach (or create) a session and return its live byte stream.
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream
    /// Start a new session running `command` (default name when nil).
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream
    func kill(name: String) async throws
    /// Set (or clear, when nil/empty) a session's display alias.
    func rename(name: String, alias: String?) async throws
    /// #590: the ended sessions dch recorded, newest first, at most 50.
    func history() async throws -> [DchHistoryRow]
    /// #590: bring a recorded session back (`nil` = every one dch can take). Returns the
    /// names it runs under: a live name comes back as a free `<name>-N`. #668: `noMessage`
    /// relaunches without typing the resume message (dch 1.27.0, `.reviveNoMessage`).
    func revive(name: String?, noMessage: Bool) async throws -> [String]
    /// #590: restart live sessions' agents (`nil` = all). Every name must be live, or none runs.
    func restart(names: [String]?) async throws -> [String]
    /// #590: stop live sessions; dch records them, so `revive` can bring them back.
    func stop(names: [String]) async throws -> [String]
    /// #614: the Mac's snippets and quicklinks, or `unchanged` when `etag` is still theirs.
    func library(etag: String?) async throws -> LibraryReply
    /// #634: pin (or unpin) a History record; a pinned one survives Clear unpinned.
    func pin(name: String, pin: Bool) async throws -> [String]
    /// #634: remove one unpinned History record; the Mac refuses a pinned one.
    func forget(name: String) async throws -> [String]
    /// #634: Clear unpinned, over every History dir.
    func forgetAll() async throws -> HistoryCleared
    /// #621: the Mac's clipboard history, newest first, paged on with `before`; only [] is the end.
    func clipboardList(limit: Int, before: String?, since: String?) async throws -> [ClipboardRow]
    /// #621: one item's bytes, refused past `max`, and the sha256 the Mac gave for them.
    /// #712: `maxSide`, an image's long side at most that, once the Mac lists clipboard_max_side.
    func clipboardItem(id: String, max: Int, maxSide: Int?) async throws -> (sha256: String, data: Data)
    /// #621: phone text into the Mac's clipboard history, never its pasteboard.
    func addClipboardHistory(_ items: [ClipboardText]) async throws -> ClipboardSent
    /// #621: one phone image into the Mac's clipboard history, on a connection of its own.
    func clipboardUpload(_ item: ClipboardUpload) async throws -> ClipboardSent
    /// #646: the Mac's local models (one, or none when it isn't on disk).
    func models() async throws -> [LocalModel]
    /// #646: one reply from the Mac's local model, chunk by chunk, on a connection of its own.
    /// Ending the stream's consumer closes the connection, which stops the generation.
    func chat(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
    /// #615: the Mac's palette commands, while its Run commands from iPhone toggle is on.
    func commands() async throws -> [MacCommand]
    /// #615: one command run on the Mac, `argument` for one that takes text.
    func runCommand(id: String, argument: String?) async throws -> CommandResult
}

/// #590: the demo and the test stubs have no dch behind them. Their machine lists no
/// `ops`, so no control calls these.
extension SessionTransport {
    func history() async throws -> [DchHistoryRow] { throw TransportError.server("Not supported here.") }
    func revive(name: String?, noMessage: Bool) async throws -> [String] { throw TransportError.server("Not supported here.") }
    func restart(names: [String]?) async throws -> [String] { throw TransportError.server("Not supported here.") }
    func stop(names: [String]) async throws -> [String] { throw TransportError.server("Not supported here.") }
    func library(etag: String?) async throws -> LibraryReply { throw TransportError.server("Not supported here.") }
    func pin(name: String, pin: Bool) async throws -> [String] { throw TransportError.server("Not supported here.") }
    func forget(name: String) async throws -> [String] { throw TransportError.server("Not supported here.") }
    func forgetAll() async throws -> HistoryCleared { throw TransportError.server("Not supported here.") }
    func clipboardList(limit: Int, before: String?, since: String?) async throws -> [ClipboardRow] {
        throw TransportError.server("Not supported here.")
    }
    func clipboardItem(id: String, max: Int, maxSide: Int?) async throws -> (sha256: String, data: Data) {
        throw TransportError.server("Not supported here.")
    }
    func addClipboardHistory(_ items: [ClipboardText]) async throws -> ClipboardSent { throw TransportError.server("Not supported here.") }
    func clipboardUpload(_ item: ClipboardUpload) async throws -> ClipboardSent { throw TransportError.server("Not supported here.") }
    func models() async throws -> [LocalModel] { throw TransportError.server("Not supported here.") }
    func chat(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: TransportError.server("Not supported here.")) }
    }
    func commands() async throws -> [MacCommand] { throw TransportError.server("Not supported here.") }
    func runCommand(id: String, argument: String?) async throws -> CommandResult { throw TransportError.server("Not supported here.") }
}

/// #590: a verb the Mac's server answers beyond the base frames. machineInfo lists them in
/// `ops`; an older Mac sends no `ops`, and every control needing one stays hidden.
enum SessionVerb: String {
    case history, revive, restart, stop, library
    case pin, forget   // #634: "forget" covers forget 0x25 and forgetAll 0x26
    case clipboard     // #621: clipboard history sync, 0x15/0x16/0x22/0x23; only while the Mac's toggle is on
    case chat          // #646: local-model chat, 0x1e/0x1f; only while the Mac's model is on disk
    case commands      // #615: palette commands, 0x28/0x29; only while the Mac's toggle is on
    case reviveNoMessage = "revive_no_message"   // #668: revive's "no_message"; only while the Mac's dch is 1.27.0+
    case clipboardMaxSide = "clipboard_max_side"   // #712: clipboardItem's "max_side"; only together with clipboard

    /// The verbs in a machineInfo `ops` value; unknown names and a missing key give none.
    /// clipboard_max_side without clipboard is none either.
    static func offered(_ ops: Any?) -> Set<SessionVerb> {
        var verbs = Set((ops as? [String] ?? []).compactMap(SessionVerb.init(rawValue:)))
        if !verbs.contains(.clipboard) { verbs.remove(.clipboardMaxSide) }
        return verbs
    }
}

/// #614: libraryResp 0x1c. The etag is opaque: kept and sent back. A file is nil when the Mac
/// has none, or with `unchanged`; `errors` says why one didn't come ("malformed JSON", …).
struct LibraryReply: Equatable {
    var etag: String
    var unchanged = false
    var snippets: Data?
    var quicklinks: Data?
    var errors: [String: String] = [:]
}

/// #621: one row of clipboardResp 0x1d. Every textual kind is "text"; `text` is its first 2000
/// characters, whole when its UTF-8 is `size` bytes.
struct ClipboardRow: Equatable {
    var id: String
    var date: String     // as the Mac wrote it: the next sync's `since`
    var kind: String     // text, image or file
    var source = "Mac"   // or "iPhone": one a phone sent
    var text: String?
    var size = 0

    /// ISO8601 with milliseconds, the Mac's precision; read with or without them.
    static func wire(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// #621: a phone clip for addClipboardHistory 0x22.
struct ClipboardText: Equatable {
    var id: UUID
    var date: Date
    var text: String
}

/// #621: a phone image for clipboardUpload 0x23, history only. #718: or the newest clip, text or
/// image, `live`: the Mac also puts it on its pasteboard.
struct ClipboardUpload: Equatable {
    var id: UUID
    var date: Date
    var data: Data
    var mime: String?
    var kind = "image"
    var live = false
}

/// #621: ok's `{added, skipped}`: the ids the Mac took, and the rest by id with its reason.
struct ClipboardSent: Equatable {
    var added: [String] = []
    var skipped: [String: String] = [:]
}

/// #646: one row of modelsResp 0x27. `loaded`: resident now, so the first reply comes quickly.
struct LocalModel: Equatable {
    var id: String
    var name: String
    var loaded: Bool
}

/// #615: one row of commandsResp 0x2a. `argument`, the input's placeholder hint, means it takes
/// text; none, it runs on a tap. `icon` is an SF Symbol name; `ext` the extension's title.
struct MacCommand: Equatable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var ext: String
    var argument: String?
    var icon: String?
}

/// #615: commandResult 0x2b: `text` shown big, `detail` small ("km → m").
struct CommandResult: Equatable {
    var text: String
    var detail: String?
}

/// #646: one message of a chat 0x1f request.
struct ChatMessage: Equatable {
    enum Role: String { case user, assistant }
    var role: Role
    var content: String
}

/// #590: one ended session from historyResp 0x1b.
struct DchHistoryRow: Equatable {
    var name: String
    var alias: String?
    var agentName: String?   // #593: the agent's session name; older Macs never send it
    var end: String          // dch's raw value: "signal 9", "exit 0", "killed"
    var lastSeen: Int        // epoch seconds
    var started: Int         // epoch seconds
    var runtime: Int         // seconds
    var cwd: String?
    var command: [String]?
    var takes: Bool
    var pinned = false       // #634: "pinned": true only on a pinned row
}

/// #634: forgetAll's tally.
struct HistoryCleared: Equatable {
    var cleared: Int
    var skipped: Int
    var failed: Int
}

enum TransportError: Error, LocalizedError {
    case notConnected
    case hostUnreachable(String)
    case rejected(String)
    case protocolError(String)
    /// #590: the server's error 0x13 message, written to be shown as is.
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:            return "Not connected."
        case .hostUnreachable(let h):  return "Can't reach \(h) — check Tailscale."
        case .rejected(let r):         return "Connection rejected: \(r)"
        case .protocolError(let m):    return "Protocol error: \(m)"
        case .server(let m):           return m
        }
    }
}
