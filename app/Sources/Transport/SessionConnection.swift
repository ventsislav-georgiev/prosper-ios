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

    /// Output sink — set by the terminal view to `terminal.feed(byteArray:)`.
    var onBytes: ((ArraySlice<UInt8>) -> Void)?

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
        stream?.resize(cols: cols, rows: rows)
    }

    func close() {
        userClosed = true
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
                stream = s
                attempt = 0
                state = .connected
                s.resize(cols: cols, rows: rows)   // correct size after a size change mid-drop
                for await chunk in s.output {
                    onBytes?(chunk)
                }
                // Stream ended. User close → done; otherwise the link dropped.
                stream = nil
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
