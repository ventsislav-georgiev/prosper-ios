import SwiftUI
import SwiftTerm
import UIKit

/// Live terminal for one session. SwiftTerm renders; `SessionConnection` keeps the
/// byte pipe alive across drops. A status chip surfaces only when reconnecting.
struct TerminalScreen: View {
    let transport: SessionTransport
    let session: DchSession
    @StateObject private var conn: SessionConnection
    @State private var handle = TermHandle()

    init(transport: SessionTransport, session: DchSession) {
        self.transport = transport
        self.session = session
        _conn = StateObject(wrappedValue: SessionConnection(transport: transport, session: session))
    }

    var body: some View {
        ZStack(alignment: .top) {
            TerminalHost(conn: conn, handle: handle)
                // The host VC owns keyboard avoidance via `keyboardLayoutGuide`. If
                // SwiftUI ALSO insets for the keyboard the two stack and the layout
                // never restores on dismiss.
                .ignoresSafeArea(.keyboard)
            statusChip
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // SwiftTerm has no dismiss control of its own.
                Button { handle.vc?.toggleKeyboard() } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
            }
        }
        .onDisappear { conn.close() }
    }

    @ViewBuilder private var statusChip: some View {
        switch conn.state {
        case .stalled, .reconnecting:
            Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule()).padding(.top, 8)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule()).padding(.top, 8)
        default:
            EmptyView()
        }
    }
}

/// Bridges the SwiftUI nav bar to the UIKit view controller (a plain reference, so
/// no SwiftUI state write happens during a view update).
final class TermHandle { weak var vc: TerminalHostVC? }

/// Hosts SwiftTerm's `TerminalView` in a view controller — needed for
/// `view.keyboardLayoutGuide` (iOS 15+), which tracks the keyboard frame and
/// resizes the terminal above it on show and restores it on hide.
private struct TerminalHost: UIViewControllerRepresentable {
    let conn: SessionConnection
    let handle: TermHandle
    func makeUIViewController(context: Context) -> TerminalHostVC {
        let vc = TerminalHostVC(conn: conn)
        handle.vc = vc
        return vc
    }
    func updateUIViewController(_ vc: TerminalHostVC, context: Context) {}
}

final class TerminalHostVC: UIViewController, TerminalViewDelegate, UIGestureRecognizerDelegate {
    private let conn: SessionConnection
    private var tv: DchTerminalView!
    private var started = false
    private var scrollRemainder: CGFloat = 0
    private var kbConstraint: NSLayoutConstraint!

    init(conn: SessionConnection) {
        self.conn = conn
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("DCHDIAG[boot] viewDidLoad")
        view.backgroundColor = .black

        let tv = DchTerminalView(frame: .zero, font: nil)
        self.tv = tv
        tv.terminalDelegate = self
        tv.backgroundColor = .black
        tv.nativeBackgroundColor = .black
        tv.contentInsetAdjustmentBehavior = .never
        // Default .scaleToFill stretches the cached layer on bounds change instead
        // of redrawing — that's the "frozen old frame" after a keyboard resize.
        // .redraw forces drawRect on every size change.
        tv.contentMode = .redraw
        tv.allowMouseReporting = true     // lets wheel events reach mouse-mode apps
        // We drive scrolling ourselves (SwiftTerm's iOS UIScrollView scrollback is
        // unreliable: it slams to the bottom on every redraw). Kill native pan-scroll.
        tv.isScrollEnabled = false
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)

        // `keyboardLayoutGuide` shrinks the grid on show but doesn't reliably
        // reclaim the space on hide (leaves a blank band). Drive the bottom
        // constraint from keyboard notifications instead — constant returns to 0
        // on dismiss, guaranteeing the grid grows back.
        kbConstraint = tv.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tv.leftAnchor.constraint(equalTo: view.leftAnchor),
            tv.rightAnchor.constraint(equalTo: view.rightAnchor),
            kbConstraint,
        ])
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(kbChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(kbHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(onForeground),
                       name: UIApplication.didBecomeActiveNotification, object: nil)

        disableSelectionGestures()
        addScrollGesture()
        addTapGesture()

        conn.onBytes = { [weak tv] slice in tv?.feed(byteArray: slice) }
        tv.onResize = { [weak self] cols, rows in
            MainActor.assumeIsolated { self?.conn.resize(cols: cols, rows: rows) }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        let t = tv.getTerminal()
        conn.start(cols: t.cols, rows: t.rows)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        _ = tv.resignFirstResponder()
    }

    /// Full dismiss (drops keyboard AND SwiftTerm's floating accessory) or raise.
    /// `resignFirstResponder` is the only thing that removes the accessory bar.
    func toggleKeyboard() {
        if tv.isFirstResponder { _ = tv.resignFirstResponder() }
        else { _ = tv.becomeFirstResponder() }
    }

    // MARK: - Scroll by swipe → terminal input

    /// Strip ALL of SwiftTerm's built-in gestures (long-press selection, multi-tap
    /// word/line select, and its single tap). We install our own tap so we control
    /// caret-tap vs mouse-click routing.
    private func disableSelectionGestures() {
        for g in tv.gestureRecognizers ?? [] {
            if g is UILongPressGestureRecognizer || g is UITapGestureRecognizer {
                tv.removeGestureRecognizer(g)
            }
        }
    }

    private func addScrollGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        tv.addGestureRecognizer(pan)
    }

    private func addTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.delegate = self
        tv.addGestureRecognizer(tap)
    }

    /// Tap on the cursor row → raise the keyboard. Tap elsewhere while a mouse-mode
    /// app is running → forward a left click (lets TUIs like Claude Code react to
    /// taps). Normal screen (no mouse mode) → always raise the keyboard.
    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let term = tv.getTerminal()
        let p = g.location(in: tv)
        let cellH = max(1, tv.bounds.height / CGFloat(max(term.rows, 1)))
        let cellW = max(1, tv.bounds.width / CGFloat(max(term.cols, 1)))
        let row = min(max(0, Int(p.y / cellH)), term.rows - 1)
        let col = min(max(0, Int(p.x / cellW)), term.cols - 1)
        let caret = term.getCursorLocation()
        if term.mouseMode != .off && row != caret.y {
            let press = term.encodeButton(button: 0, release: false, shift: false, meta: false, control: false)
            term.sendEvent(buttonFlags: press, x: col, y: row)
            let release = term.encodeButton(button: 0, release: true, shift: false, meta: false, control: false)
            term.sendEvent(buttonFlags: release, x: col, y: row)
        } else {
            _ = tv.becomeFirstResponder()
        }
    }

    // MARK: - Keyboard avoidance

    @objc private func kbChange(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let endInView = view.convert(end, from: nil)
        let safeBottomY = view.bounds.maxY - view.safeAreaInsets.bottom
        kbConstraint.constant = -max(0, safeBottomY - endInView.minY)
        view.layoutIfNeeded()
        diag("kbChange")
        refreshAfterKeyboard(n)
    }

    @objc private func kbHide(_ n: Notification) {
        kbConstraint.constant = 0
        view.layoutIfNeeded()
        diag("kbHide")
        refreshAfterKeyboard(n)
    }

    /// The grid resizes correctly on keyboard show/hide, but SwiftTerm's iOS view
    /// leaves stale pixels until something forces a full redraw — backgrounding then
    /// foregrounding the app fixes it. Reproduce that: after the keyboard animation
    /// settles AND the app's SIGWINCH repaint round-trips, force a full relayout +
    /// display invalidation. Two ticks (settle, then post-repaint) cover both.
    private func refreshAfterKeyboard(_ n: Notification) {
        let dur = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        forceRedraw()
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self] in self?.forceRedraw() }
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.2) { [weak self] in self?.forceRedraw() }
    }

    /// Reproduce what background→foreground does: re-send the terminal size to the
    /// server. TIOCSWINSZ fires SIGWINCH even when the dimensions are unchanged, so
    /// the inner app (Claude Code) does a full reflow + repaint. The grid resize
    /// during the keyboard animation lands on intermediate sizes and the final one's
    /// reflow gets lost; this corrective resize after settle is what sticks. Also
    /// mark all rows dirty + empty feed so SwiftTerm's own view repaints.
    private func forceRedraw() {
        tv.setNeedsLayout()
        tv.layoutIfNeeded()
        let t = tv.getTerminal()
        conn.resize(cols: t.cols, rows: t.rows)
        t.refresh(startRow: 0, endRow: t.rows)
        tv.feed(byteArray: ArraySlice<UInt8>())
        diag("forceRedraw")
    }

    @objc private func onForeground() {
        diag("foreground-before")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.diag("foreground-after") }
    }

    private func diag(_ tag: String) {
        let t = tv.getTerminal()
        NSLog("DCHDIAG[\(tag)] cols=\(t.cols) rows=\(t.rows) bounds=\(tv.bounds.size) offY=\(tv.contentOffset.y) contentH=\(tv.contentSize.height) lines=\(t.getTopVisibleRow()) alt=\(t.isCurrentBufferAlternate)")
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: scrollRemainder = 0
        case .changed:
            let term = tv.getTerminal()
            let cell = max(1, tv.bounds.height / CGFloat(max(term.rows, 1)))
            let dy = g.translation(in: tv).y + scrollRemainder
            let steps = Int(dy / cell)
            guard steps != 0 else { return }
            scrollRemainder = dy - CGFloat(steps) * cell
            g.setTranslation(.zero, in: tv)
            // Finger moving DOWN (steps > 0) reveals older content = scroll up.
            emitScroll(up: steps > 0, count: abs(steps), term: term)
        default: break
        }
    }

    /// Mirror SwiftTerm's macOS `scrollWheel`: mouse-mode apps get wheel events,
    /// alternate-screen apps (less/vim/TUIs) get arrow keys, a normal screen scrolls
    /// SwiftTerm's own local scrollback.
    private func emitScroll(up: Bool, count: Int, term: Terminal) {
        if tv.allowMouseReporting && term.mouseMode != .off {
            let flags = term.encodeButton(button: up ? 4 : 5, release: false,
                                          shift: false, meta: false, control: false)
            for _ in 0..<count { term.sendEvent(buttonFlags: flags, x: 1, y: 1) }
        } else if term.isCurrentBufferAlternate {
            let seq: [UInt8] = up
                ? (term.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
                : (term.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            for _ in 0..<count { tv.send(seq) }
        } else {
            if up { tv.scrollUp(lines: count) } else { tv.scrollDown(lines: count) }
        }
    }

    // Let our scroll pan and the single-tap coexist.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: - TerminalViewDelegate (nonisolated; SwiftTerm calls on main)

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { conn.send(data) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Reports view-driven grid changes so the pty resizes to match.
private final class DchTerminalView: TerminalView {
    var onResize: ((Int, Int) -> Void)?
    private var lastCols = 0
    private var lastRows = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let t = getTerminal()
        if t.cols != lastCols || t.rows != lastRows {
            lastCols = t.cols
            lastRows = t.rows
            onResize?(t.cols, t.rows)
        }
    }
}
