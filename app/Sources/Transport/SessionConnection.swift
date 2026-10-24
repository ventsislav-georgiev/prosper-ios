import Foundation
import UIKit

/// Drives one attached session and keeps it alive across drops (PLAN §15.1). The
/// terminal view feeds bytes in via `send`/`resize` and renders bytes out via
/// `onBytes`. On an unexpected stream end it silently reattaches with backoff; the
/// user only sees a "Reconnecting…" chip if recovery takes longer than the grace
/// period. dch repaints the current screen on every reattach (MSG_ATTACH →
/// SIGWINCH), so a reconnect restores the live TUI with no replay buffer needed.
@MainActor
final class SessionConnection: ObservableObject {
    @Published private(set) var state: ConnectionState = .connecting
    /// One quiet status line, gone after `noticeLife` or on entering `.failed` (the retry
    /// capsule wins). A refused paste also clears on the next accepted write; a sticky
    /// one (a paste lost in reconnect) outlives typing, or the user never sees it, but
    /// not time: it still goes after `noticeLife` (QA #62), the status line stays free.
    @Published private(set) var notice: String?
    private var noticeSticky = false
    private var noticeClear: Task<Void, Never>?
    static var noticeLife: Duration = .seconds(4)

    let session: DchSession
    private let transport: SessionTransport
    private let backoff: BackoffPolicy
    private var stream: TerminalStream?
    private var loop: Task<Void, Never>?
    private var userClosed = false
    private var cols = 80
    private var rows = 24
    /// When the session last wrote anything — the quiet gate for `resync`.
    private var lastBytes = ContinuousClock.now
    private var snapshotWait: Task<Void, Never>?

    /// Whether `stream` may take input directly — see `goLive`.
    private var live = false
    private var liveFallback: Task<Void, Never>?
    /// User writes no stream could take yet, oldest first. Delivered in order, never
    /// dropped short of the cap, cleared only when the session is over. Always a PREFIX
    /// of what the user entered since the last full flush: see `lossy`.
    private var outbox: [Outbound] = []
    private var outboxBytes = 0
    /// Something the user entered was dropped (`write` refused it, or `requeue` evicted
    /// it). Until the outbox has flushed to empty on a live stream, or is cleared, new
    /// input is refused too: queued behind the gap, a later Return would run the line
    /// without what was lost (QA #90: "echo rm -rf *" running as "rm -rf *").
    private var lossy = false
    /// Where the next `onUnsent` hand-back goes: ahead of everything queued after the
    /// stream that accepted it stopped taking input.
    private var requeueAt = 0
    /// Counts attached streams; `sentGen` is the newest one that took any input. A
    /// hand-back from an older stream than that is too late to keep its place (#230).
    private var gen = 0
    private var sentGen = 0
    /// A paste's frames so far, waiting for its closer (`send`).
    private var heldPaste: [UInt8]?
    private var pasteWait: Task<Void, Never>?

    /// ponytail: 64 KB of keystrokes/paste held across a drop, counted as framed bytes —
    /// a bracketed paste's 12-byte wrapper included, so 65524 bytes of pasted text. A
    /// write that would push the queue past it is refused, and so is everything after it
    /// (`lossy`); nothing already queued is ever dropped for it. A single write over the
    /// cap gets its own `notice`; only a live stream with nothing queued takes one. Clipboard images don't count — one per
    /// explicit paste-image tap. Raise if pastes routinely exceed it.
    static let outboxCap = 64 * 1024
    /// Longest wait for the reattached session's first output before flushing anyway.
    static let liveFallback: Duration = .seconds(1)
    /// Bracketed-paste opener (`TerminalMath.pasteBytes`): what marks a frame as a paste.
    static let pasteOpen = Array("\u{1b}[200~".utf8)
    static let pasteClose = Array("\u{1b}[201~".utf8)
    /// ponytail: longest hold for a paste's closer (`send`); past it the held bytes go out
    /// as they are. SwiftTerm sends all three parts in one main-thread turn.
    static var pasteWaitMax: Duration = .seconds(2)
    /// ponytail: an unwrapped frame over this is typed text (SwiftTerm's own paste with
    /// a stale bracketed mode, dictation/IME commits, a scroll burst), not one key or
    /// escape sequence. Raise if long key sequences start showing the notice.
    static let keystrokeMax = 16
    /// Bytes waiting for a stream (tests).
    var queuedByteCount: Int { outboxBytes }

    /// Output sink — set by the terminal view to `terminal.feed(byteArray:)`.
    var onBytes: ((ArraySlice<UInt8>) -> Void)?
    /// Full-screen sink — a `resync()` reply carrying dch's rendered screen.
    var onScreen: ((ArraySlice<UInt8>) -> Void)?

    init(transport: SessionTransport, session: DchSession, backoff: BackoffPolicy = BackoffPolicy()) {
        self.transport = transport
        self.session = session
        self.backoff = backoff
    }

    func start(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        guard loop == nil else { return }
        loop = Task { await self.runLoop() }
    }

    /// The user's "try again" after the backoff gave up: the same attach loop a fresh
    /// open runs, at the last known size. A no-op in any other state.
    func retry() {
        guard case .failed = state, !userClosed else { return }
        state = .connecting
        loop = Task { await self.runLoop() }
    }

    /// Keystrokes and pastes. Goes straight out on a live stream with nothing queued;
    /// otherwise queues behind what's already waiting, so order survives any drop.
    /// A paste split over sends (SwiftTerm's own paste was opener, text and closer; it
    /// now goes through `TerminalMath.pasteBytes`, #262) is held until the closer and
    /// written as ONE frame (#253), so a drop loses or resends the whole paste, never a
    /// lone ESC[201~ that zsh, past KEYTIMEOUT, turns into a bell and "~". Pasted text is
    /// sanitized in `pasteBytes`, not here: this layer can't tell a pasted ESC from a key.
    func send(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        heldPaste = (heldPaste ?? []) + bytes
        guard Self.opensPaste(heldPaste!) else { flushPaste(); return }
        pasteWait = pasteWait ?? Task { [weak self] in
            try? await Task.sleep(for: Self.pasteWaitMax)
            if !Task.isCancelled { self?.flushPaste() }
        }
    }

    /// Writes what the paste hold has, as it is.
    private func flushPaste() {
        pasteWait?.cancel()
        pasteWait = nil
        if let b = heldPaste { heldPaste = nil; write(.bytes(b)) }
    }

    /// Opens a bracketed paste and doesn't close it: the frames so far of one still coming.
    static func opensPaste(_ b: [UInt8]) -> Bool {
        b.starts(with: pasteOpen) && b.firstRange(of: pasteClose) == nil
    }

    /// Live with nothing queued: straight out. Otherwise queued at the end, unless the
    /// queue is `lossy` or this frame would push it past the cap: then it is refused and
    /// the queue goes lossy, so the outbox stays a prefix of what the user entered.
    private func write(_ out: Outbound) {
        guard !isOver else { return }
        if outbox.isEmpty, live, let s = stream {
            if push(out, to: s) { clearNotice(); return }
            live = false   // closed under us: queue for the next stream
        }
        let size = Self.size(out)
        if size > Self.outboxCap {
            lossy = true
            show("Paste too large to send while offline (\((size + 1023) / 1024) KB)")
            return
        }
        if lossy || outboxBytes + size > Self.outboxCap { lose([out]); return }
        clearNotice()
        outbox.append(out)
        outboxBytes += size
    }

    private static func size(_ out: Outbound) -> Int {
        if case .bytes(let b) = out { b.count } else { 0 }   // images don't count
    }

    private func show(_ text: String, sticky: Bool = false) {
        notice = text
        noticeSticky = sticky
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeLife)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Input clears a refusal notice; only `force` (entering `.failed`) clears a sticky one.
    private func clearNotice(force: Bool = false) {
        guard notice != nil, force || !noticeSticky else { return }
        noticeClear?.cancel()
        notice = nil
    }

    private func push(_ out: Outbound, to s: TerminalStream) -> Bool {
        switch out {
        case .bytes(let b):     guard s.send(b[...]) else { return false }
        case .clipboard(let d): guard s.putClipboard(d) else { return false }
        }
        sentGen = gen   // only ever pushed to the current stream
        return true
    }

    /// Nothing will take queued input on this run: closed by the user, ended, or `.failed`.
    /// The outbox is cleared on reaching any of these. `.failed` is not final — the user
    /// can `retry()` it — but per OQ-13 (a) input is not held for after a retry: the terminal
    /// is dimmed and refuses the keyboard while failed, and this drop is the backstop.
    private var isOver: Bool {
        if userClosed { return true }
        switch state {
        case .ended, .failed: return true
        default: return false
        }
    }

    /// The attached session can take input. Not at attach: the server spawns a fresh
    /// `dch` client per connection, and until it has put its pty in raw mode the line
    /// discipline echoes our bytes, eats DEL/^U/^W and turns ^C into a SIGINT that
    /// kills the client (→ "session ended"). dch prints nothing before raw mode, so
    /// the first output byte is the signal; the fallback covers a silent session.
    private func goLive(_ s: TerminalStream) {
        guard stream === s, !live else { return }
        live = true
        liveFallback?.cancel()
        flushOutbox()
    }

    private func flushOutbox() {
        guard live, let s = stream else { return }
        var sent = 0
        while let next = outbox.first {
            guard push(next, to: s) else { live = false; break }
            outbox.removeFirst()
            sent += 1
            outboxBytes -= Self.size(next)
        }
        if outbox.isEmpty { lossy = false }   // the gap is behind us: input may queue again
        // Everything still queued came after what this stream just took, so its
        // hand-backs go to the front, not behind hand-backs it never reached.
        if sent > 0 { requeueAt = 0 }
    }

    /// A frame the transport took but couldn't put on the wire: back in line, ahead of
    /// everything typed after it. Unless it comes from an older stream than one that has
    /// already taken input (a hand-back that missed its stream's end; ProsperStream's
    /// close failsafe hands back what it still holds first, #251): it can no longer go
    /// ahead of that input, and sent behind it the host sees the keys out of order —
    /// dropped instead, with `lostNotice`, or for keys the typed notice: sent at once on a
    /// live stream (no `lossy` gate on that path), the user saw nothing go (#289).
    ///
    /// A hand-back that pushes the queue past the cap is kept: it is older than every
    /// frame behind it. The NEWEST whole frames go from the end until it fits (never a
    /// cut one: a cut paste loses its ESC[200~ opener and every line runs as a command),
    /// and the queue goes `lossy`. Earlier hand-backs ahead of it stay too.
    ///
    /// Known duplicate window (#251/#253): the close failsafe hands back every frame
    /// whose completion had not reported after 1 s, and some of those did reach the
    /// host (a completion that was stuck, or raced the failsafe). Resent here, such a
    /// frame runs twice — and since a paste is one frame, that is a WHOLE paste: zsh,
    /// bash and node run the command twice when the paste ends with CR. Without an
    /// app-level ack from the server there is no telling which frames arrived; accepted.
    private func requeue(_ out: Outbound, from g: Int) {
        guard !isOver else { return }
        // A paste is one frame (`send`), so it is dropped whole. CSI/SS3-led frames (ESC[ / ESC O:
        // arrows, scroll bursts, SGR mouse reports) stay silent, as does a lone ESC[201~ (only after
        // `pasteWaitMax`): zsh already ended paste mode on KEYTIMEOUT, and a stray closer
        // rings the bell and inserts "~" (#241 QA #63). Typed keys (`isTypedKey`: plain bytes, a
        // lone Esc, alt+key incl. alt+é) get the typed notice: a lost Esc makes vim insert the next command.
        if g < sentGen {
            if let text = Self.lostNotice(for: out) { show(text, sticky: true) }
            else if case .bytes(let b) = out, Self.isTypedKey(b) { showTypedLost() }
            return
        }
        let at = min(requeueAt, outbox.count)
        outbox.insert(out, at: at)
        requeueAt += 1
        outboxBytes += Self.size(out)
        var lost: [Outbound] = []
        while outboxBytes > Self.outboxCap, outbox.count > at + 1 {
            let last = outbox.removeLast()
            outboxBytes -= Self.size(last)
            lost.insert(last, at: 0)
        }
        if !lost.isEmpty { lose(lost) }
        flushOutbox()
    }

    /// What to tell the user about a dropped hand-back: a paste by its ESC[200~ opener,
    /// an image, unwrapped text by size. A lost keystroke, or a frame opening with ESC
    /// (keys, CSI, a scroll burst of arrows or SGR mouse reports), is harmless to redo
    /// and stays silent.
    static let pasteLost = "Paste lost in reconnect, paste again"
    static let typedLost = "Typed text lost in reconnect, type it again"

    /// A typed key: not ESC-led, a lone Esc, or alt+key (ESC + char; optionAsMetaKey makes alt+é
    /// ESC + multibyte UTF-8, #304). Any 2-byte ESC-led frame is alt+key, since no control
    /// sequence is that short: alt+[, alt+O, alt+] and ESC ESC are typed. From 3 bytes on, a
    /// second byte of `[` (CSI: cursor/function keys, mouse reports), `O` (SS3), ESC (a
    /// meta-prefixed sequence such as alt+arrow ESC ESC [ A), or `]` / `P` / `_` / `^` (the
    /// OSC / DCS / APC / PM replies the terminal sends to nvim/vim queries, #309) is not typed.
    /// Except a kitty keyboard protocol key report (`isKittyKey`, #314): under the flags nvim and
    /// fish push, Esc is ESC[27u and ctrl+a ESC[97;5u, so those are typed keys.
    static func isTypedKey(_ b: [UInt8]) -> Bool {
        isKittyKey(b) || b.first != 0x1b || b.count <= 2 || !Set<UInt8>([0x1b, 0x5b, 0x4f, 0x5d, 0x50, 0x5f, 0x5e]).contains(b[1])
    }

    /// ESC [ <digits ; :> u. The reply to a kitty flags query, ESC[?1u, starts with `?` and is not one.
    static func isKittyKey(_ b: [UInt8]) -> Bool {
        b.count >= 4 && b[0] == 0x1b && b[1] == 0x5b && b.last == 0x75
            && b[2...].dropLast().allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x3b || $0 == 0x3a }
    }

    static func lostNotice(for out: Outbound) -> String? {
        switch out {
        case .clipboard: return "Image paste lost in reconnect, paste again"
        case .bytes(let b) where b.starts(with: pasteOpen): return pasteLost
        case .bytes(let b) where b.first != 0x1b && b.count > keystrokeMax: return typedLost
        case .bytes: return nil
        }
    }

    /// Frames the outbox dropped or refused: the queue goes `lossy`. A paste, image or
    /// long typed text gets its `lostNotice`, sticky: the next key would otherwise clear
    /// it before it was read. Lost keys (silent in `lostNotice`) get the typed notice
    /// once, unless a sticky notice is already up; a paste-lost one doesn't count, so
    /// it never hides that keys went too: the typed notice replaces it.
    private func lose(_ frames: [Outbound]) {
        lossy = true
        var keys = false
        for f in frames {
            if let text = Self.lostNotice(for: f) { show(text, sticky: true) } else { keys = true }
        }
        if keys { showTypedLost() }
    }

    private func showTypedLost() {
        if notice == nil || !noticeSticky || notice == Self.pasteLost { show(Self.typedLost, sticky: true) }
    }

    private func clearOutbox() {
        outbox.removeAll()
        outboxBytes = 0
        requeueAt = 0
        lossy = false
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        // A mirror request still waiting to fire was queued for the OLD grid. dch's copy
        // is a screen at that geometry, so painting it after a resize re-narrows the
        // reflowed screen — the black right half after rotating into landscape. The
        // resize itself makes the remote repaint; the mirror has nothing left to add.
        snapshotWait?.cancel()
        stream?.resize(cols: cols, rows: rows)
    }

    func redraw() {
        assertSize()
        stream?.requestRedraw()
    }

    /// Re-tell the session how wide we are before every repair.
    ///
    /// A dch session has ONE size, and the last client to report wins — other phones,
    /// the Mac's own terminal, and (until keepalive reaps them) clients left behind by
    /// dropped connections all move it. Once someone else has narrowed the session, our
    /// grid hasn't changed, so the resize-on-grid-change path stays silent and the
    /// remote program keeps wrapping to a width we don't have: the screen looks garbled
    /// and the redraw button "does nothing" because it repaints at the wrong width.
    private func assertSize() { stream?.resize(cols: cols, rows: rows) }

    /// Image paste: load the remote machine's clipboard, then let the caller send
    /// the paste keystroke. Frames are ordered on one connection and the server sets
    /// the clipboard before acking, so a ctrl-V sent right after lands second.
    /// Queued like keystrokes, so it stays ahead of the ctrl-V that follows it.
    func putClipboard(_ image: Data) { flushPaste(); write(.clipboard(image)) }

    /// Repair the screen after anything that can leave it stale (rotation, font
    /// change, foreground, reattach). Two independent paths, weakest first:
    /// `requestRedraw` nudges the remote program to repaint itself, and the
    /// snapshot pulls dch's VT mirror — which is correct even when the program
    /// never repaints.
    ///
    /// The snapshot prefers a quiet session: the mirror only equals the true screen once
    /// the remote program has finished writing. Claude Code answers a resize on its own
    /// render tick (~1s), so a fixed short delay painted the pre-reflow screen over the
    /// correct one — after rotating the phone the terminal kept the old, narrower layout.
    ///
    /// But quiet is a preference, not a requirement, and waiting for it forever is what
    /// made the redraw button useless on the one program that needs it most: a working
    /// Claude Code repaints its spinner several times a second, so the gap between bytes
    /// never opens, and the snapshot that would have fixed the screen was dropped. Past
    /// the deadline we take the mirror as-is — well after any reflow, and a torn spinner
    /// frame is corrected by its own next tick a moment later.
    func resync() {
        assertSize()
        stream?.requestRedraw()
        snapshotWait?.cancel()
        snapshotWait = Task { [weak self] in
            let start = ContinuousClock.now
            while let self, !Task.isCancelled {
                let sinceBytes = self.lastBytes.duration(to: .now)
                let waited = start.duration(to: .now)
                if waited > Self.snapshotDeadline { break }   // busy screen: take it anyway
                if waited > .milliseconds(500), sinceBytes > .milliseconds(600) { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.stream?.requestSnapshot()
        }
    }

    /// How long to hold out for a quiet session before taking the mirror anyway. Past
    /// Claude Code's ~1s render tick with margin, under the patience of a finger that
    /// just pressed redraw.
    static let snapshotDeadline: Duration = .milliseconds(2500)

    func close() {
        userClosed = true
        snapshotWait?.cancel()
        loop?.cancel()
        liveFallback?.cancel()
        stream?.close()
        stream = nil
        live = false
        clearOutbox()
    }

    /// Attach → pump output until the stream ends → reattach with backoff until the
    /// user closes or the policy is exhausted.
    private func runLoop() async {
        var attempt = 0
        while !userClosed {
            do {
                let s = try await transport.attach(name: session.name, cols: cols, rows: rows)
                // Closed while the attach was in flight: don't install a stream nobody owns.
                if userClosed { s.close(); return }
                s.onScreen = { [weak self] screen in
                    Task { @MainActor in self?.onScreen?(screen) }
                }
                // Main queue, not a Task: hand-backs must land in the order they were
                // made, and before the stream-end the loop sees next.
                gen += 1
                let g = gen
                s.onUnsent = { [weak self] out in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.requeue(out, from: g) } }
                }
                stream = s
                live = false
                liveFallback?.cancel()
                liveFallback = Task { [weak self, weak s] in
                    try? await Task.sleep(for: Self.liveFallback)
                    guard !Task.isCancelled, let self, let s else { return }
                    self.goLive(s)
                }
                attempt = 0
                state = .connected
                s.resize(cols: cols, rows: rows)   // correct size after a size change mid-drop
                // Force a repaint: a TUI parked on a modal prompt (Claude Code's
                // question dialogs) ignores the attach-time WINCH and renders black
                // until a keypress. The server jiggles the pty size, which no TUI
                // can ignore — and the snapshot paints dch's mirror regardless.
                resync()
                for await chunk in s.output {
                    lastBytes = .now
                    onBytes?(chunk)
                    if !live { goLive(s) }
                }
                // Stream ended. Clean exit / user close → done; otherwise the link dropped.
                stream = nil
                live = false
                liveFallback?.cancel()
                if s.exited { state = .ended; clearOutbox(); return }
                if userClosed { return }
            } catch {
                stream = nil
                live = false
                if userClosed { return }
            }
            // Reconnect path.
            attempt += 1
            if attempt > backoff.maxAttempts {
                state = .failed("Couldn't reconnect to \(session.title).")
                clearOutbox()
                clearNotice(force: true)
                return
            }
            state = attempt == 1 ? .stalled : .reconnecting(attempt: attempt)
            let delay = backoff.delay(attempt: attempt, rand: Double.random(in: 0..<1))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
