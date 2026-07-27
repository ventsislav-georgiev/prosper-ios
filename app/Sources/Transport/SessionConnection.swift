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

    func send(_ bytes: ArraySlice<UInt8>) { stream?.send(bytes) }

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
    func putClipboard(_ image: Data) { stream?.putClipboard(image) }

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
        stream?.close()
        stream = nil
    }

    /// Attach → pump output until the stream ends → reattach with backoff until the
    /// user closes or the policy is exhausted.
    private func runLoop() async {
        var attempt = 0
        while !userClosed {
            do {
                let s = try await transport.attach(name: session.name, cols: cols, rows: rows)
                s.onScreen = { [weak self] screen in
                    Task { @MainActor in self?.onScreen?(screen) }
                }
                stream = s
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
                }
                // Stream ended. Clean exit / user close → done; otherwise the link dropped.
                stream = nil
                if s.exited { state = .ended; return }
                if userClosed { return }
            } catch {
                stream = nil
                if userClosed { return }
            }
            // Reconnect path.
            attempt += 1
            if attempt > backoff.maxAttempts {
                state = .failed("Couldn't reconnect to \(session.title).")
                return
            }
            state = attempt == 1 ? .stalled : .reconnecting(attempt: attempt)
            let delay = backoff.delay(attempt: attempt, rand: Double.random(in: 0..<1))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
