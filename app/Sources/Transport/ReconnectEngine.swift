import Foundation

/// Connection lifecycle (PLAN §15.1). The UI freezes the last frame on `.stalled`
/// and only surfaces a "Reconnecting…" chip after a grace delay.
enum ConnectionState: Equatable {
    case connecting
    case connected
    case stalled          // transient: drop detected, retrying silently
    case reconnecting(attempt: Int)
    case failed(String)   // permanent: backoff exhausted / rejected
    case ended            // clean exit: the remote process finished (e.g. `exit`)
    case waking(deadline: Date)   // remote wake sent; retrying TCP until the Mac answers
}

/// Fast backoff for invisible recovery (PLAN §15.1): 0, 150ms, 400ms, 1s, 2s …
/// capped at 5s, with full jitter so a fleet of clients doesn't thunder.
/// First retry is near-instant — most mobile drops are sub-second roaming.
struct BackoffPolicy {
    var base: [Double] = [0, 0.15, 0.4, 1.0, 2.0]
    var cap: Double = 5.0
    var maxAttempts: Int = 12

    /// Delay (seconds) before attempt `n` (1-based). `rand` in [0,1) is the
    /// jitter source — injected so this is deterministic to test.
    func delay(attempt n: Int, rand: Double) -> Double {
        let idx = max(0, n - 1)
        let ceiling = idx < base.count ? base[idx] : cap
        return ceiling * rand   // full jitter: uniform in [0, ceiling]
    }
}

#if DEBUG
/// ponytail: one runnable check for the non-trivial backoff math.
func _backoffSelfCheck() {
    let p = BackoffPolicy()
    // rand=1.0 → the ceiling itself; verifies the schedule + cap.
    assert(p.delay(attempt: 1, rand: 1) == 0)
    assert(p.delay(attempt: 2, rand: 1) == 0.15)
    assert(p.delay(attempt: 5, rand: 1) == 2.0)
    assert(p.delay(attempt: 99, rand: 1) == p.cap)      // beyond schedule → cap
    // full jitter stays within [0, ceiling]
    assert(p.delay(attempt: 5, rand: 0.5) == 1.0)
    assert(p.delay(attempt: 5, rand: 0) == 0)
}
#endif
