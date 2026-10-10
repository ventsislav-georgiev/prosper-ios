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
    /// one (a paste lost in reconnect) outlives typing, or the user never sees it.
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
    /// dropped short of the cap, cleared only when the session is over.
    private var outbox: [Outbound] = []
    private var outboxBytes = 0
    /// Where the next `onUnsent` hand-back goes: ahead of everything queued after the
    /// stream that accepted it stopped taking input.
    private var requeueAt = 0
    /// Counts attached streams; `sentGen` is the newest one that took any input. A
    /// hand-back from an older stream than that is too late to keep its place (#230).
    private var gen = 0
    private var sentGen = 0

    /// ponytail: 64 KB of keystrokes/paste held across a drop, counted as framed bytes —
    /// a bracketed paste's 12-byte wrapper included, so 65524 bytes of pasted text; past it the OLDEST whole
    /// frames go. A frame is never cut. A single write over the cap is refused up front
    /// with a `notice` (it could never survive the next frame queued behind it); only a
    /// live stream with nothing queued takes one. Clipboard images don't count — one per
    /// explicit paste-image tap. Raise if pastes routinely exceed it.
    static let outboxCap = 64 * 1024
    /// Longest wait for the reattached session's first output before flushing anyway.
    static let liveFallback: Duration = .seconds(1)
    /// Bracketed-paste opener (`TerminalMath.pasteBytes`): what marks a frame as a paste.
    static let pasteOpen = Array("\u{1b}[200~".utf8)
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
    func send(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        write(.bytes(Array(bytes)))
    }

    private func write(_ out: Outbound) {
        guard !isOver else { return }
        if outbox.isEmpty, live, let s = stream {
            if push(out, to: s) { clearNotice(); return }
            live = false   // closed under us: queue for the next stream
        }
        if case .bytes(let b) = out, b.count > Self.outboxCap {
            show("Paste too large to send while offline (\((b.count + 1023) / 1024) KB)")
            return
        }
        clearNotice()
        outbox.append(out)
        if case .bytes(let b) = out { outboxBytes += b.count }
        trimOutbox()
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
    /// can `retry()` it — input typed while failed is dropped today; OQ-13 decides whether
    /// to hold it.
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
            if case .bytes(let b) = next { outboxBytes -= b.count }
        }
        // Everything still queued came after what this stream just took, so its
        // hand-backs go to the front, not behind hand-backs it never reached.
        if sent > 0 { requeueAt = 0 }
    }

    /// A frame the transport took but couldn't put on the wire: back in line, ahead of
    /// everything typed after it. Unless it comes from an older stream than one that has
    /// already taken input (a hand-back that missed its stream's end; ProsperStream's
    /// close failsafe hands back what it still holds first, #251): it can no longer go
    /// ahead of that input, and sent behind it the host sees the keys out of order —
    /// dropped instead, with `lostNotice`.
    private func requeue(_ out: Outbound, from g: Int) {
        guard !isOver else { return }
        // A late lone ESC[201~ (SwiftTerm sends a paste's closer as its own frame) is
        // dropped too: zsh already ended paste mode on KEYTIMEOUT, and a stray closer
        // rings the bell and inserts a literal "~" (#241 QA #63).
        if g < sentGen {
            if let text = Self.lostNotice(for: out) { show(text, sticky: true) }
            return
        }
        outbox.insert(out, at: min(requeueAt, outbox.count))
        requeueAt += 1
        if case .bytes(let b) = out { outboxBytes += b.count }
        trimOutbox()
        flushOutbox()
    }

    /// What to tell the user about a dropped hand-back: a paste by its ESC[200~ opener,
    /// an image, unwrapped text by size. A lost keystroke, or a frame opening with ESC
    /// (keys, CSI, a scroll burst of arrows or SGR mouse reports), is harmless to redo
    /// and stays silent.
    static func lostNotice(for out: Outbound) -> String? {
        switch out {
        case .clipboard: return "Image paste lost in reconnect, paste again"
        case .bytes(let b) where b.starts(with: pasteOpen): return "Paste lost in reconnect, paste again"
        case .bytes(let b) where b.first != 0x1b && b.count > keystrokeMax: return "Typed text lost in reconnect, type it again"
        case .bytes: return nil
        }
    }

    /// Drops the oldest WHOLE frames until the queue fits the cap. Never cuts one: a cut
    /// paste loses its ESC[200~ opener and every pasted line runs as a command, and a
    /// cut keystroke frame can split a CSI or UTF-8 sequence. The last frame always
    /// stays: `write` refuses a single frame over the cap, but a hand-back (`requeue`) of
    /// one a live stream took is kept whole.
    private func trimOutbox() {
        var i = 0
        while outboxBytes > Self.outboxCap, i < outbox.count - 1 {
            guard case .bytes(let b) = outbox[i] else { i += 1; continue }
            outbox.remove(at: i)
            outboxBytes -= b.count
            if i < requeueAt { requeueAt -= 1 }
        }
    }

    private func clearOutbox() {
        outbox.removeAll()
        outboxBytes = 0
        requeueAt = 0
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
    func putClipboard(_ image: Data) { write(.clipboard(image)) }

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
