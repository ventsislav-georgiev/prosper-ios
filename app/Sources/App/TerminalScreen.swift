import SwiftUI
import SwiftTerm
import UIKit
import UniformTypeIdentifiers

/// Live terminal for one session. SwiftTerm renders; `SessionConnection` keeps the
/// byte pipe alive across drops. A status chip surfaces only when reconnecting.
struct TerminalScreen: View {
    let transport: SessionTransport
    let session: DchSession
    @StateObject private var conn: SessionConnection
    @StateObject private var handle = TermHandle()
    @State private var editingShortcuts = false
    @State private var confirmKill = false
    @Environment(\.dismiss) private var dismiss

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
                // Kill the session from inside the terminal — `exit` alone can't
                // end it when the server predates the exit frame.
                Button(role: .destructive) { confirmKill = true } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { editingShortcuts = true } label: { Image(systemName: "slider.horizontal.3") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                // SwiftTerm has no dismiss control of its own.
                Button { handle.vc?.toggleKeyboard() } label: {
                    Image(systemName: handle.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                }
            }
        }
        .sheet(isPresented: $editingShortcuts, onDismiss: { handle.vc?.reloadShortcuts() }) {
            ShortcutEditor()
        }
        .alert("Stop \(session.title)?", isPresented: $confirmKill) {
            Button("Stop", role: .destructive) {
                Task {
                    conn.close()
                    try? await transport.kill(name: session.name)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(conn.$state) { state in
            // Remote process finished (`exit`) — pop back to the session list
            // instead of reattaching (which would recreate the session).
            if state == .ended { dismiss() }
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

/// Bridges the SwiftUI nav bar to the UIKit view controller. `keyboardShown` drives
/// the toolbar toggle icon; the VC publishes it on show/hide.
final class TermHandle: ObservableObject {
    weak var vc: TerminalHostVC?
    @Published var keyboardShown = false
}

/// Hosts SwiftTerm's `TerminalView` in a view controller — needed for
/// `view.keyboardLayoutGuide` (iOS 15+), which tracks the keyboard frame and
/// resizes the terminal above it on show and restores it on hide.
private struct TerminalHost: UIViewControllerRepresentable {
    let conn: SessionConnection
    let handle: TermHandle
    func makeUIViewController(context: Context) -> TerminalHostVC {
        let vc = TerminalHostVC(conn: conn, handle: handle)
        handle.vc = vc
        return vc
    }
    func updateUIViewController(_ vc: TerminalHostVC, context: Context) {}
}

final class TerminalHostVC: UIViewController, TerminalViewDelegate, UIGestureRecognizerDelegate {
    private let conn: SessionConnection
    private let handle: TermHandle
    private var tv: DchTerminalView!
    private var started = false
    private var selAnchor: Position?
    private var scrollThumb: ScrollThumb?
    private var kbConstraint: NSLayoutConstraint!
    private var barHeight: NSLayoutConstraint!
    // Where the wheel strip ends: the screen bottom, or the shortcut bar's top once the
    // keyboard is up. Exactly one is active — the pill rests in the middle of it.
    private var thumbBottom: NSLayoutConstraint!
    private var thumbBottomKeyboard: NSLayoutConstraint!
    private var pendingRemoteScroll = 0            // jog lines held for the next batch
    private var lastRemoteScrollSend: CFTimeInterval = 0
    private var kbOverlap: CGFloat = 0   // keyboard cover height while shown (for live re-lift)
    private var kbFrame: CGRect?         // last keyboard frame (screen coords), re-applied after rotation
    private var ctrlArmed = false   // sticky Ctrl from the shortcut bar
    /// Non-nil while a scroll burst is being assembled: SwiftTerm's output lands here
    /// instead of the socket, so N wheel events cost one write. See `emitScroll`.
    private var coalescing: [UInt8]?
    private var shortcutBar: ShortcutBar?

    /// macOS Terminal.app's vibrant 16-color ANSI palette (SwiftTerm's default is
    /// muted). 8-bit values widened to 16-bit (×257 maps 255→65535).
    static let ansiPalette: [SwiftTerm.Color] = [
        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
    ].map { SwiftTerm.Color(red: UInt16($0.0) * 257, green: UInt16($0.1) * 257, blue: UInt16($0.2) * 257) }

    init(conn: SessionConnection, handle: TermHandle) {
        self.conn = conn
        self.handle = handle
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let tv = DchTerminalView(frame: .zero, font: TerminalFont.mono(size: TerminalPrefs.fontSize))
        self.tv = tv
        tv.terminalDelegate = self
        tv.backgroundColor = .black
        tv.nativeBackgroundColor = .black
        tv.installColors(TerminalHostVC.ansiPalette)   // vibrant 16-color ANSI (matches macOS Terminal)
        tv.contentInsetAdjustmentBehavior = .never
        // Default .scaleToFill stretches the cached layer on bounds change instead
        // of redrawing — that's the "frozen old frame" after a keyboard resize.
        // .redraw forces drawRect on every size change.
        tv.contentMode = .redraw
        tv.allowMouseReporting = true     // lets wheel events reach mouse-mode apps
        // We drive scrolling ourselves (SwiftTerm's iOS UIScrollView scrollback is
        // unreliable: it slams to the bottom on every redraw). Kill native pan-scroll.
        tv.isScrollEnabled = false
        // SwiftTerm installs its own TerminalAccessory as inputAccessoryView; drop it —
        // we render our own shortcut bar in the VC hierarchy instead.
        tv.inputAccessoryView = nil
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)

        // DECOUPLED keyboard avoidance: the terminal keeps its FULL height at all
        // times so the grid NEVER resizes on keyboard show/hide. Resizing the grid
        // forced the remote TUI to reflow, and Claude Code defers its repaint to its
        // own render tick (~1s) — leaving the freed rows blank after the keyboard
        // hides. With a fixed grid there is no reflow and no repaint gap.
        // Instead, on show we translate the terminal UP (see kbChange) so the cursor/
        // input row stays visible above the keyboard; the top rows clip off-screen.
        // The shortcut bar lives in our own hierarchy (not inputAccessoryView — the
        // keyboard's remote input window swallowed its touches), glued to the top of
        // the keyboard via kbConstraint, and OVERLAYS the terminal's lower rows.
        view.clipsToBounds = true   // clip the translated-up terminal at the view top
        let bar = ShortcutBar()
        bar.onKey = { [weak self] key in self?.handleKey(key) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.clipsToBounds = true
        view.addSubview(bar)
        shortcutBar = bar

        kbConstraint = bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        barHeight = bar.heightAnchor.constraint(equalToConstant: 0)   // hidden until keyboard shows
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tv.leftAnchor.constraint(equalTo: view.leftAnchor),
            tv.rightAnchor.constraint(equalTo: view.rightAnchor),
            tv.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), // FULL height, fixed
            bar.leftAnchor.constraint(equalTo: view.leftAnchor),
            bar.rightAnchor.constraint(equalTo: view.rightAnchor),
            kbConstraint,
            barHeight,
        ])
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(kbChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(kbHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
        // A clean repaint on foreground (the system usually does this, but the
        // forced path guarantees no stale pixels survive a background round-trip).
        nc.addObserver(self, selector: #selector(onForeground),
                       name: UIApplication.didBecomeActiveNotification, object: nil)

        disableSelectionGestures()
        addSelectionGesture()
        addTapGesture()
        addScrollThumb()

        conn.onScreen = { [weak self] screen in
            MainActor.assumeIsolated { self?.applyScreen(screen) }
        }
        conn.onBytes = { [weak self, weak tv] slice in
            tv?.feed(byteArray: slice)
            // Dynamic re-lift: as output streams and the caret moves down, keep the
            // bottom row above the keyboard. rangeChanged doesn't fire reliably on
            // stream (verified in the spike) — the feed path is the dependable hook.
            MainActor.assumeIsolated { self?.relift() }
        }
        tv.onResize = { [weak self] cols, rows in
            MainActor.assumeIsolated { self?.conn.resize(cols: cols, rows: rows) }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startIfNeeded()
    }

    /// Attach once, at the grid size the view settled on.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        let size = terminalSize
        conn.start(cols: size.cols, rows: size.rows)
    }

    /// The grid the view currently presents — what the pty must be told to match.
    var terminalSize: (cols: Int, rows: Int) {
        let t = tv.getTerminal()
        return (t.cols, t.rows)
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

    /// Rebuild the shortcut bar after the editor changed the key set, and pick up a
    /// new text size. A font change reflows the grid (SwiftTerm recomputes cols/rows
    /// in layoutSubviews → onResize → pty resize), then we repaint from scratch.
    func reloadShortcuts() {
        shortcutBar?.reload()
        let size = TerminalPrefs.fontSize
        if tv.font.pointSize != size {
            tv.font = TerminalFont.mono(size: size)
            tv.setNeedsLayout()
            tv.layoutIfNeeded()          // settle the new grid before we state its size
            repairAfterSizeChange()      // a new cell size is a new grid — same rules as rotation
        }
    }

    /// Force a full repaint — the button form of "resize the window to fix it".
    ///
    /// Local half: mark every row dirty and run a display pass, so nothing that was
    /// already received stays unpainted.
    ///
    /// Remote half (`conn.resync()`): what actually fixes missing glyphs. The remote
    /// program's idea of the screen and ours have diverged — it thinks it already
    /// drew those cells, so it will never send them again. The server jiggles the pty
    /// size (which Node/Ink apps treat as a real resize and re-render on) and then
    /// hands us dch's own VT mirror, which is authoritative even when the program
    /// repaints nothing at all. `applyScreen` paints it.
    ///
    /// `mirror: false` keeps the jiggle and drops the mirror — for repairs that follow
    /// a GRID CHANGE, where dch's copy was captured at the old width. See
    /// `repairAfterSizeChange`.
    func forceRedraw(mirror: Bool = true) {
        let t = tv.getTerminal()
        t.refresh(startRow: 0, endRow: max(0, t.rows - 1))
        tv.feed(byteArray: [])   // queuePendingDisplay() is internal; feed is the public door
        if mirror { conn.resync() } else { conn.redraw() }
    }

    /// Repair after the grid itself changed size (rotation).
    ///
    /// Two departures from the plain repair, both learned from landscape coming back
    /// with the right half black:
    ///
    /// State the measured grid outright instead of trusting the layout pass to have
    /// reported it. `onResize` fires from `layoutSubviews` only when SwiftTerm's cols/rows
    /// actually changed; anything that swallows that one callback leaves the pty at the
    /// portrait width, and the remote program keeps wrapping to a width we don't have.
    /// Re-stating a size we already sent costs one frame and is a no-op at the pty.
    ///
    /// And skip dch's mirror. It is a snapshot of the screen at the OLD geometry: the
    /// remote reflows on the SIGWINCH the resize just caused, but it only re-emits cells
    /// it thinks changed — so painting the old-width mirror on top of the reflowed screen
    /// re-narrows it permanently. The pty jiggle still forces Ink/Claude to re-render,
    /// which is the half that matters after a resize, and a program that ignores WINCH
    /// wrote nothing new for the mirror to hold anyway.
    func repairAfterSizeChange() {
        // Settle the layout before measuring. A rotation coordinator's completion can run
        // before the new bounds have reached the terminal view, and measuring there would
        // re-state the size we already had.
        view.layoutIfNeeded()
        let grid = terminalSize
        conn.resize(cols: grid.cols, rows: grid.rows)
        forceRedraw(mirror: false)
    }

    /// Paint dch's rendered screen over ours — see `TerminalMath.snapshotPaint` for
    /// the byte sequence and how the caret is placed.
    private func applyScreen(_ screen: ArraySlice<UInt8>) {
        guard !screen.isEmpty else { return }
        let out = TerminalMath.snapshotPaint(screen)
        tv.feed(byteArray: out[...])
        // The mirror IS the live screen, so show the live screen: painting it while
        // the user is scrolled back leaves the caret and the input row above the
        // viewport, looking like input landing outside the terminal.
        if tv.canScroll { tv.scroll(toPosition: 1) }
        relift()
    }

    /// Rotation changes the grid: the remote program reflows to the new size but
    /// repaints only what it thinks changed, so the screen can come back partly
    /// blank. Resync from dch's mirror once the new size settles, and refit the
    /// keyboard geometry to the new bounds (the frame UIKit posted mid-rotation was
    /// measured against the old ones).
    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            if let f = self.kbFrame, self.handle.keyboardShown {
                self.applyKeyboard(f, notification: nil)
            }
            self.relift()
            self.repairAfterSizeChange()
        }
    }

    /// A shortcut-bar key was tapped.
    private func handleKey(_ key: ShortcutKey) {
        switch key.kind {
        case .ctrl:
            ctrlArmed.toggle()
            shortcutBar?.ctrlArmed = ctrlArmed
        case .pasteText:
            if let s = UIPasteboard.general.string, let d = s.data(using: .utf8), !d.isEmpty {
                conn.send(ArraySlice(d))
            }
        case .pasteImage:
            pasteImage(then: key.bytes)
        case .bytes:
            conn.send(ArraySlice(key.bytes))
        case .redraw:
            forceRedraw()
        }
        if tv.isFirstResponder == false { _ = tv.becomeFirstResponder() }
    }

    /// Push the copied image to the remote machine's clipboard, then send the paste
    /// keystroke (ctrl-V) that makes the TUI read it. Claude Code's image paste looks
    /// at the clipboard of the machine it runs on, so the keystroke alone only ever
    /// worked when Universal Clipboard had carried the phone's image to the Mac.
    ///
    /// With nothing image-shaped on the pasteboard, still send the keystroke: the
    /// remote clipboard may well hold the image already.
    ///
    /// ponytail: sends the image at full size. Downscale if big screenshots ever feel
    /// slow over the tailnet.
    func pasteImage(then keystroke: [UInt8]) {
        if let png = copiedImagePNG() { conn.putClipboard(png) }
        conn.send(ArraySlice(keystroke))
    }

    /// The copied image as PNG, whatever the pasteboard is holding it as. Photos hands
    /// over HEIC as often as PNG, and Claude Code reads the clipboard as PNG
    /// (`the clipboard as «class PNGf»`), so anything else is converted here rather
    /// than shipped in a form the far end can't use.
    func copiedImagePNG() -> Data? {
        let pb = UIPasteboard.general
        // `hasImages` answers from the type list alone — no paste prompt, and nothing
        // read — so a bar press with text on the clipboard stays silent.
        guard pb.hasImages else { return nil }
        if let png = pb.data(forPasteboardType: UTType.png.identifier), !png.isEmpty { return png }
        for id in pb.types where UTType(id)?.conforms(to: .image) == true {
            guard let data = pb.data(forPasteboardType: id), !data.isEmpty else { continue }
            if let png = UIImage(data: data)?.pngData() { return png }
        }
        return pb.image?.pngData()
    }

    /// Map a byte to its control-char form (a–z/A–Z → ^A–^Z, others via `& 0x1f`).
    private func controlByte(_ b: UInt8) -> UInt8 {
        let upper = (b >= 0x61 && b <= 0x7a) ? b - 0x20 : b
        return upper & 0x1f
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

    /// Pan on the terminal text = text selection (like dragging over text in a
    /// browser). Scrolling moved to the edge thumb — one finger motion, one job.
    private func addSelectionGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onSelectPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        tv.addGestureRecognizer(pan)
    }

    /// Big auto-hiding jog wheel on the right edge. Tap the screen to reveal it;
    /// hold it off center to scroll that way, faster the further you pull. Only the
    /// terminal view scrolls — no bytes reach the remote app except the scroll itself.
    private func addScrollThumb() {
        let thumb = ScrollThumb()
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.onJog = { [weak self] lines in self?.jogScroll(lines) }
        thumb.onJogEnd = { [weak self] in self?.jogScroll(0, endOfDrag: true) }
        view.addSubview(thumb)
        // The strip spans what you can SEE, and the pill rests in the middle of it, so
        // every inset here reads as "the wheel starts off center". Visible starts under
        // the nav bar — which sits INSIDE the top safe area, so `tv.top` is that edge;
        // anchoring to `view.top` hid a nav bar's worth of strip behind the bar and
        // parked the pill half of it high. Visible ends at the screen bottom (the bottom
        // safe area is empty black screen), or at the shortcut bar once the keyboard is
        // up — measured against the bar itself, not the keyboard height, which is
        // relative to the safe area and would leave the pill half an inset low.
        thumbBottom = thumb.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        thumbBottomKeyboard = thumb.bottomAnchor.constraint(
            equalTo: shortcutBar?.topAnchor ?? view.bottomAnchor)
        NSLayoutConstraint.activate([
            thumb.rightAnchor.constraint(equalTo: view.rightAnchor),
            thumb.topAnchor.constraint(equalTo: tv.topAnchor),
            thumbBottom,
            thumb.widthAnchor.constraint(equalToConstant: ScrollThumb.trackWidth),
        ])
        scrollThumb = thumb
    }

    /// One tick of the jog wheel: signed whole lines, negative = up. Every scroll in
    /// the app funnels through `emitScroll`, so mouse-mode apps, alternate-screen TUIs
    /// and plain scrollback each get the form they understand.
    ///
    /// Scrollback is local and goes out per frame. Anything the REMOTE has to answer is
    /// batched (see `TerminalMath.remoteScrollBatch`) — one arrow key per frame makes the
    /// remote repaint the whole screen 60 times a second, which is what tore and stuttered.
    func jogScroll(_ lines: Int, endOfDrag: Bool = false) {
        let term = tv.getTerminal()
        guard isRemoteScroll(term) else {
            guard lines != 0 else { return }
            emitScroll(up: lines < 0, count: abs(lines), term: term)
            return
        }
        let now = CACurrentMediaTime()
        let send = TerminalMath.batchRemoteScroll(
            pending: &pendingRemoteScroll, add: lines,
            sinceLastSend: now - lastRemoteScrollSend, force: endOfDrag)
        guard send != 0 else { return }
        lastRemoteScrollSend = now
        emitScroll(up: send < 0, count: abs(send), term: term)
    }

    /// True when scrolling is a round-trip: a mouse-reporting app, or the alternate
    /// screen where there is no scrollback of our own to move.
    private func isRemoteScroll(_ term: Terminal) -> Bool {
        (tv.allowMouseReporting && term.mouseMode != .off) || term.isCurrentBufferAlternate
    }

    private func addTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.delegate = self
        tv.addGestureRecognizer(tap)
    }

    /// Grid cell under a point in `tv` coordinates.
    private func gridPos(_ p: CGPoint, _ term: Terminal) -> (row: Int, col: Int) {
        TerminalMath.gridCell(point: p, size: tv.bounds.size, rows: term.rows, cols: term.cols)
    }

    /// Tap on the cursor row → raise the keyboard. Tap elsewhere while a mouse-mode
    /// app is running → forward a left click (lets TUIs like Claude Code react to
    /// taps). Normal screen (no mouse mode) → always raise the keyboard.
    /// Every tap also flashes the scroll thumb, and a tap with an active selection
    /// just clears it (standard text-selection behavior).
    @objc private func onTap(_ g: UITapGestureRecognizer) {
        scrollThumb?.show()
        if tv.hasActiveSelection {
            tv.clearSelection()
            return
        }
        let term = tv.getTerminal()
        let p = g.location(in: tv)
        let (row, col) = gridPos(p, term)
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
        kbFrame = end
        applyKeyboard(end, notification: n)
    }

    /// Fit the bar and the lift to a keyboard frame (screen coordinates).
    ///
    /// Split out of `kbChange` because rotation posts the new keyboard frame while
    /// `view` is still the old orientation: the overlap then comes out measured
    /// against the wrong height, which left the shortcut bar floating mid-screen and
    /// the input row lifted out of view. `viewWillTransition` re-applies the same
    /// frame once the bounds have caught up.
    private func applyKeyboard(_ end: CGRect, notification n: Notification?) {
        let endInView = view.convert(end, from: nil)
        let safeBottomY = view.bounds.maxY - view.safeAreaInsets.bottom
        let overlap = max(0, safeBottomY - endInView.minY)
        let shown = overlap > 0
        kbConstraint.constant = -overlap   // glue the shortcut bar to the keyboard top
        barHeight.constant = shown ? ShortcutBar.barHeight : 0
        // Keep the wheel resting in the middle of the SHRUNKEN screen.
        thumbBottom.isActive = !shown
        thumbBottomKeyboard.isActive = shown
        handle.keyboardShown = shown
        kbOverlap = shown ? overlap : 0
        animateKeyboard(n, offset: shown ? caretLiftOffset(overlap: overlap) : 0)
    }

    @objc private func kbHide(_ n: Notification) {
        kbConstraint.constant = 0
        barHeight.constant = 0
        thumbBottomKeyboard.isActive = false
        thumbBottom.isActive = true
        handle.keyboardShown = false
        kbOverlap = 0
        animateKeyboard(n, offset: 0)
    }

    /// Re-run the lift as content streams in (output fills the screen, the caret
    /// drops to the bottom) while the keyboard is already up — so the bottom row
    /// keeps tracking just above the keyboard. Instant (no animation) to follow
    /// output smoothly; a no-op when the offset hasn't changed.
    private func relift() {
        guard kbOverlap > 0 else { return }
        let offset = caretLiftOffset(overlap: kbOverlap)
        let t = offset > 0 ? CGAffineTransform(translationX: 0, y: -offset) : .identity
        if tv.transform != t { tv.transform = t }
    }

    /// How far to lift the terminal so the lowest non-empty row clears the bar+keyboard.
    /// Content-aware, not bottom-anchored: a fresh session (content at the TOP, empty
    /// bottom) gets ~0 lift so its input stays visible, while Claude (input + 3 HUD
    /// lines at the bottom) lifts the full covered height. Lift only what's needed.
    private func caretLiftOffset(overlap: CGFloat) -> CGFloat {
        let visibleH = tv.bounds.height - ShortcutBar.barHeight - overlap
        let contentBottom = tv.contentBottomY() + 8   // small breathing room below content
        // Never lift past the strip the bar and keyboard actually cover: clearing them
        // is the whole job, and anything beyond pushes the input row off the TOP of
        // the screen. The cell height behind `contentBottom` comes from SwiftTerm's
        // caret frame, which is briefly stale mid-rotation — this is the ceiling that
        // keeps that from throwing the layout.
        return min(max(0, contentBottom - visibleH), overlap + ShortcutBar.barHeight)
    }

    /// Slide the terminal up by `offset` and lay out the bar, riding the keyboard's
    /// own animation curve/duration. The grid never resizes (tv bounds are fixed), so
    /// there is no SIGWINCH and no remote repaint — the freed-rows blank gap is gone.
    private func animateKeyboard(_ n: Notification?, offset: CGFloat) {
        let dur = (n?.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: dur) {
            self.tv.transform = offset > 0 ? CGAffineTransform(translationX: 0, y: -offset) : .identity
            self.view.layoutIfNeeded()
        }
    }

    @objc private func onForeground() { forceRedraw() }

    /// Drag over the text = select it. Coordinates are buffer-relative (view row +
    /// top visible row) so a selection survives local scrollback moves.
    @objc private func onSelectPan(_ g: UIPanGestureRecognizer) {
        let term = tv.getTerminal()
        let p = g.location(in: tv)
        let (row, col) = gridPos(p, term)
        let pos = Position(col: col, row: row + term.getTopVisibleRow())
        switch g.state {
        case .began:
            selAnchor = pos
        case .changed:
            guard let anchor = selAnchor else { return }
            tv.setSelectionRange(start: anchor, end: pos)
        case .ended:
            selAnchor = nil
            // Release over a real selection → the standard Copy menu at the finger.
            if tv.hasActiveSelection { tv.showStandardContextMenu(at: p) }
        default:
            selAnchor = nil
        }
    }

    /// Mirror SwiftTerm's macOS `scrollWheel`: mouse-mode apps get wheel events,
    /// alternate-screen apps (less/vim/TUIs) get arrow keys, a normal screen scrolls
    /// SwiftTerm's own local scrollback.
    private func emitScroll(up: Bool, count: Int, term: Terminal) {
        if tv.allowMouseReporting && term.mouseMode != .off {
            let flags = term.encodeButton(button: up ? 4 : 5, release: false,
                                          shift: false, meta: false, control: false)
            // Each sendEvent hands its bytes straight back through the delegate, so a
            // burst of ten wheel events used to be ten writes — and a mouse-mode app
            // (Claude Code) answers EVERY one with a full repaint. That's what the
            // batching was supposed to prevent, and this was the path it missed.
            // Catching them turns the burst into the single write the far end wants.
            coalescing = []
            for _ in 0..<count { term.sendEvent(buttonFlags: flags, x: 1, y: 1) }
            let burst = coalescing ?? []
            coalescing = nil
            if !burst.isEmpty { conn.send(ArraySlice(burst)) }
        } else if term.isCurrentBufferAlternate {
            let seq: [UInt8] = up
                ? (term.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
                : (term.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            // ONE write for the whole burst: the remote reads all the keys in a single
            // chunk and answers with a single repaint, which is the point of batching.
            var burst = [UInt8]()
            burst.reserveCapacity(seq.count * count)
            for _ in 0..<count { burst.append(contentsOf: seq) }
            tv.send(burst)
        } else {
            if up { tv.scrollUp(lines: count) } else { tv.scrollDown(lines: count) }
        }
    }

    // Let our scroll pan and the single-tap coexist.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: - TerminalViewDelegate (nonisolated; SwiftTerm calls on main)

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            if coalescing != nil {
                coalescing?.append(contentsOf: data)   // scroll burst — one write, see emitScroll
            } else if ctrlArmed, let b = data.first {
                ctrlArmed = false
                shortcutBar?.ctrlArmed = false
                conn.send(ArraySlice([controlByte(b)]))
            } else {
                conn.send(data)
            }
        }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    /// Nothing to sync: the jog wheel shows no position, it rests centered. (Reporting
    /// one was the bug — SwiftTerm defines `position` as 0 for the alternate screen,
    /// where every full-screen TUI lives, so the pill jumped to the top on every chunk
    /// of output.)
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { relift() }
}

/// Reports view-driven grid changes so the pty resizes to match.
/// FiraCode Nerd Font Mono, bundled so folder/git/powerline glyphs (Nerd Font
/// private-use codepoints) render instead of `?`/.notdef. Registered once at process
/// scope; falls back to the system monospace if the bundle is missing the files.
enum TerminalFont {
    private static let registered: Bool = {
        var ok = false
        for file in ["FiraCodeNerdFontMono-Regular", "FiraCodeNerdFontMono-Bold"] {
            if let url = Bundle.main.url(forResource: file, withExtension: "ttf") {
                ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) || ok
            }
        }
        return ok
    }()

    static func mono(size: CGFloat) -> UIFont {
        _ = registered
        return UIFont(name: "FiraCodeNFM-Reg", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Auto-hiding jog wheel for scrolling the terminal. A 44 pt touch strip on the
/// right edge that ALWAYS owns its touches — a pan there can never start a text
/// selection on the terminal below.
///
/// It is a spring-centered wheel, not a scrollbar: the pill rests in the middle,
/// scrolls while held off center (faster the further off), and springs back on
/// release. A scrollbar can't work here — the alternate screen every full-screen TUI
/// runs in has no scrollback to be positioned in, so there is no position to show
/// and no absolute target to drag to.
private final class ScrollThumb: UIView {
    static let trackWidth: CGFloat = 44
    private static let pillSize = CGSize(width: 18, height: 88)
    private static let idleDelay: TimeInterval = 1.6
    /// Deflection is capped here rather than at the track ends: the wheel reaches full
    /// speed within a thumb's reach, so scrolling never needs a full-screen drag.
    private static let maxTravel: CGFloat = 90

    /// Signed whole lines to scroll for this tick; negative = up.
    var onJog: ((Int) -> Void)?
    /// The drag ended — whoever batches scroll must flush what it still holds.
    var onJogEnd: (() -> Void)?

    private let pill = UIView()
    private var pillY: NSLayoutConstraint!
    private var hideTimer: Timer?
    private var jog: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var remainder: CGFloat = 0
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.alpha = 0   // the strip stays hit-testable; only the pill fades
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        pill.layer.cornerRadius = Self.pillSize.width / 2
        pill.isUserInteractionEnabled = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        pillY = pill.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            pill.rightAnchor.constraint(equalTo: rightAnchor, constant: -4),
            pill.widthAnchor.constraint(equalToConstant: Self.pillSize.width),
            pill.heightAnchor.constraint(equalToConstant: Self.pillSize.height),
            pillY,
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Any touch on the strip reveals the pill — including the very first one,
    /// so "tap near the right edge, then drag" always scrolls, never selects.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        show()
    }

    func show() {
        hideTimer?.invalidate()
        if pill.alpha < 1 { UIView.animate(withDuration: 0.15) { self.pill.alpha = 1 } }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay, repeats: false) { [weak self] _ in
            guard let self, !self.dragging else { return }
            UIView.animate(withDuration: 0.3) { self.pill.alpha = 0 }
        }
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            dragging = true
            remainder = 0
            show()
            hideTimer?.invalidate()
            startJog()
        case .changed:
            let dy = g.translation(in: self).y
            g.setTranslation(.zero, in: self)
            let limit = min(Self.maxTravel, max(0, (bounds.height - Self.pillSize.height) / 2))
            pillY.constant = min(max(pillY.constant + dy, -limit), limit)
        default:
            dragging = false
            stopJog()
            recenter()
            scheduleHide()
        }
    }

    /// Spring back to the middle so the next pull has full travel both ways.
    private func recenter() {
        pillY.constant = 0
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.7,
                       initialSpringVelocity: 0) { self.layoutIfNeeded() }
    }

    private func startJog() {
        guard jog == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // 60 Hz, not the 120 Hz a ProMotion screen offers: the terminal repaints at most
        // once per 16.7 ms, so faster ticks don't draw more — they just split the same
        // motion into steps of 0, 1, 0, 1 lines that land two-at-a-time in one repaint.
        // Ticking at the redraw rate makes every drawn frame advance evenly.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        jog = link
    }

    private func stopJog() {
        jog?.invalidate()
        jog = nil
        onJogEnd?()
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = CGFloat(now - lastTick)
        lastTick = now
        let travel = min(Self.maxTravel, max(0, (bounds.height - Self.pillSize.height) / 2))
        let lines = TerminalMath.jogLines(offset: pillY.constant, travel: travel,
                                         elapsed: elapsed, remainder: &remainder)
        if lines != 0 { onJog?(lines) }
    }
}

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

    /// Y (tv-local, pre-transform) of the bottom edge of the lowest non-empty row.
    /// Drives the keyboard lift so the real content bottom — not the empty grid
    /// bottom — clears the keyboard. Handles Claude's input + 3 HUD footer lines
    /// (lifted as a block) and a fresh top-anchored prompt (no lift) identically.
    func contentBottomY() -> CGFloat {
        let t = getTerminal()
        let cellH = caretFrame.height > 0 ? caretFrame.height
                  : bounds.height / CGFloat(max(1, t.rows))
        var r = t.rows - 1
        while r > 0, !(t.getLine(row: r)?.hasAnyContent() ?? false) { r -= 1 }
        return CGFloat(r + 1) * cellH
    }
}
