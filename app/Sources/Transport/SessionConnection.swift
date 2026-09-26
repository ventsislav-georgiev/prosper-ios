import Foundation

/// Drives one attached session and keeps it alive across drops (PLAN §15.1). The
/// terminal view feeds bytes in via `send`/`resize` and renders bytes out via
/// `onBytes`. On an unexpected stream end it silently reattaches with backoff; the
/// user only sees a "Reconnecting…" chip if recovery takes longer than the grace
/// period. dch repaints the current screen on every reattach (MSG_ATTACH →
/// SIGWINCH), so a reconnect restores the live TUI with no replay buffer needed.
@MainActor
final class SessionConnection: ObservableObject {
    @Published private(set) var state: ConnectionState = .connecting

    let session: DchSession
    private let transport: SessionTransport
    private let backoff = BackoffPolicy()
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

    /// ponytail: 64 KB of keystrokes/paste held across a drop; past it the OLDEST bytes
    /// go (a long paste typed into a dead link keeps its tail). Clipboard images don't
    /// count — one per explicit paste-image tap. Raise if pastes routinely exceed it.
    static let outboxCap = 64 * 1024
    /// Longest wait for the reattached session's first output before flushing anyway.
    static let liveFallback: Duration = .seconds(1)
    /// Bytes waiting for a stream (tests).
    var queuedByteCount: Int { outboxBytes }

    /// Output sink — set by the terminal view to `terminal.feed(byteArray:)`.
    var onBytes: ((ArraySlice<UInt8>) -> Void)?
    /// Full-screen sink — a `resync()` reply carrying dch's rendered screen.
    var onScreen: ((ArraySlice<UInt8>) -> Void)?

    init(transport: SessionTransport, session: DchSession) {
        self.transport = transport
        self.session = session
    }

    func start(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        guard loop == nil else { return }
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
            if push(out, to: s) { return }
            live = false   // closed under us: queue for the next stream
        }
        outbox.append(out)
        if case .bytes(let b) = out { outboxBytes += b.count }
        trimOutbox()
    }

    private func push(_ out: Outbound, to s: TerminalStream) -> Bool {
        switch out {
        case .bytes(let b):     return s.send(b[...])
        case .clipboard(let d): return s.putClipboard(d)
        }
    }

    /// Session over for good — nothing will ever take queued input.
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
        requeueAt = max(0, requeueAt - sent)
    }

    /// A frame the transport took but couldn't put on the wire: back in line, ahead of
    /// everything typed after it.
    private func requeue(_ out: Outbound) {
        guard !isOver else { return }
        outbox.insert(out, at: min(requeueAt, outbox.count))
        requeueAt += 1
        if case .bytes(let b) = out { outboxBytes += b.count }
        trimOutbox()
        flushOutbox()
    }

    private func trimOutbox() {
        var i = 0
        while outboxBytes > Self.outboxCap, i < outbox.count {
            guard case .bytes(let b) = outbox[i] else { i += 1; continue }
            let excess = outboxBytes - Self.outboxCap
            if b.count <= excess {
                outbox.remove(at: i)
                outboxBytes -= b.count
                if i < requeueAt { requeueAt -= 1 }
            } else {
                outbox[i] = .bytes(Array(b.dropFirst(excess)))
                outboxBytes -= excess
            }
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
                s.onUnsent = { [weak self] out in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.requeue(out) } }
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
                return
            }
            state = attempt == 1 ? .stalled : .reconnecting(attempt: attempt)
            let delay = backoff.delay(attempt: attempt, rand: Double.random(in: 0..<1))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
