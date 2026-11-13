import Foundation

/// Offline demo so the app is fully usable with no Mac/Tailscale host — for
/// first-run exploration and App Review (a reviewer can't join your tailnet).
/// Plays a canned, interactive-looking session into SwiftTerm via the normal
/// `TerminalStream` contract: scripted output on attach, then it echoes typed
/// input so the keyboard + shortcut bar are demonstrable. No real shell runs
/// (iOS can't fork/exec) — typed commands get a friendly "connect a real
/// machine" reply.
final class DemoTransport: SessionTransport {
    func listSessions() async throws -> [DchSession] {
        [DchSession(name: "demo", alias: "Demo session", state: "idle"),
         DchSession(name: "claude", alias: "claude (sample)", state: "working", agents: 2, meta: SessionMeta(
            open: [12, 15, 18, 21].map { (n: Int) in      // no URL: the sample repo doesn't exist
                SessionMeta.PR(url: nil, repo: "example/app", num: n, title: "Sample change #\(n)")
            }, merged: 4)),
         // More made-up rows so the list reads like a working day: one waiting, one busy, one done.
         DchSession(name: "api", alias: "api refactor", state: "blocked", agents: 1, meta: SessionMeta(
            open: [SessionMeta.PR(url: nil, repo: "example/api", num: 31, title: "Sample refactor")])),
         DchSession(name: "web", alias: "web build", state: "working"),
         DchSession(name: "docs", alias: "docs site", state: "done", meta: SessionMeta(merged: 2))]
    }
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream {
        DemoStream(kind: name == "claude" ? .claude : .shell)
    }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        DemoStream(kind: (name == "claude") ? .claude : .shell)
    }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}

final class DemoStream: TerminalStream {
    enum Kind { case shell, claude }

    let output: AsyncStream<ArraySlice<UInt8>>
    let exited = false   // demo sessions never exit on their own
    private let cont: AsyncStream<ArraySlice<UInt8>>.Continuation
    private var line: [UInt8] = []
    private let kind: Kind

    // Neon palette (matches the Prosper theme): cyan + bright blue.
    private let cyan = "\u{1b}[38;2;33;204;255m"
    private let blue = "\u{1b}[38;2;117;235;255m"
    private let dim = "\u{1b}[38;2;120;140;160m"
    private let green = "\u{1b}[38;2;126;231;135m"     // diff additions
    private let greenBg = "\u{1b}[48;2;13;43;19m"      // added-line highlight
    private let white = "\u{1b}[38;2;230;236;243m"
    private let reset = "\u{1b}[0m"

    init(kind: Kind = .shell) {
        self.kind = kind
        var c: AsyncStream<ArraySlice<UInt8>>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        cont = c
        Task { kind == .claude ? await playClaude() : await play() }
    }

    private func emit(_ s: String) { cont.yield(ArraySlice(Array(s.utf8))) }
    private func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    private func prompt() {
        if kind == .claude { emit("\(blue)\u{203a}\(reset) ") }     // ›
        else { emit("\(cyan)prosper@demo\(reset):\(blue)~\(reset) $ ") }
    }

    /// Type `s` at a fresh prompt, char-by-char, then newline.
    private func typeLine(_ s: String) async {
        prompt()
        for ch in s { emit(String(ch)); await pause(26) }
        emit("\r\n")
    }

    // MARK: - A sample agent session

    /// Stream `s` word-by-word for a live, "thinking" feel.
    private func streamWords(_ s: String, _ msPerWord: UInt64 = 22) async {
        for (i, word) in s.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            emit(i == 0 ? String(word) : " " + word)
            await pause(msPerWord)
        }
    }
    private func diffAdd(_ n: Int, _ text: String) {
        let num = String(n).leftPad(3)
        emit("\(greenBg)\(dim) \(num) \(green)+ \(text)\u{1b}[K\(reset)\r\n")
    }
    private func diffCtx(_ n: Int, _ text: String) {
        emit("\(dim) \(String(n).leftPad(3)) \(reset)  \(text)\r\n")
    }
    private func narrator(_ s: String) async {
        emit(dim)
        await streamWords("\(s)\(reset)", 20)
        emit("\r\n\r\n")
    }
    private func bullet(_ s: String) async {
        emit("\(white)\u{2022}\(reset) ")  // •
        await streamWords(s, 18)
        emit("\r\n")
    }
    private func toolOut(_ s: String) { emit("\(dim)  \u{21b3}\(reset) \(s)\r\n") }  // ↳

    private func playClaude() async {
        emit("\u{1b}[2J\u{1b}[H")
        await pause(300)
        // Every line fits 44 columns, the narrowest phone the demo runs on.
        diffCtx(11, "## Unreleased")
        diffCtx(12, "")
        diffAdd(13, "- Wake toggle reads sign-in on the")
        diffAdd(14, "  main thread, so the phone shows")
        diffAdd(15, "  the wake-ready badge again.")
        diffCtx(16, "")
        diffCtx(17, "## 2.4.0")
        emit("\r\n")
        await pause(500)
        await narrator("Build is green. Committing and pushing.")
        await bullet("git commit -m \"fix(wake): …\"")
        toolOut("\(blue)72064e5\(reset) fix(wake): read sign-in on main")
        emit("\r\n")
        await bullet("git push origin main")
        toolOut("To github.com:example/app.git")
        toolOut("   2484a36..72064e5  main \u{2192} main")
        emit("\r\n")
        await bullet("scripts/release.sh beta")
        toolOut("Releasing v2.4.1-beta.1")
        toolOut(" * [new tag]  v2.4.1-beta.1")
        emit("\r\n")
        await pause(300)
        await narrator("Tag pushed; CI builds and signs it.")
        await bullet("Shipped \(white)v2.4.1-beta.1\(reset).")
        emit("\r\n\(dim)Done in 3m 32s\(reset)\r\n\r\n")
        prompt()
    }

    private func play() async {
        emit("\u{1b}[2J\u{1b}[H")  // clear + home. Every line fits 44 columns, the narrowest phone.
        emit("\(cyan)  Prosper \u{00b7} Remote Terminal\(reset)\(dim) demo\(reset)\r\n")
        emit("\(dim)  Your Mac's sessions, over Tailscale.\(reset)\r\n")
        emit("\(dim)  No passwords.\(reset)\r\n\r\n")
        await pause(450)
        await typeLine("ls ~/projects")
        emit("app   docs   notes.md   scripts   \(blue)site\(reset)\r\n")
        await pause(350)
        await typeLine("uname -msr")
        emit("Darwin 25.5.0 arm64\r\n")
        await pause(300)
        await typeLine("echo \"your Mac, anywhere\"")
        emit("your Mac, anywhere\r\n")
        await pause(250)
        emit("\r\n\(dim)  Try typing below. Connect a real Mac\r\n  to run live commands.\(reset)\r\n\r\n")
        prompt()
    }

    private var esc = false, csi = false   // ESC / ESC[ in flight: swallow the sequence

    func send(_ bytes: ArraySlice<UInt8>) -> Bool {
        for b in bytes {
            // Arrow keys and the bracketed-paste marks would otherwise echo as "[A"/"[200~".
            if csi { if (0x40...0x7e).contains(b) { csi = false }; continue }
            if esc { esc = false; csi = b == 0x5b; continue }
            switch b {
            case 0x1b: esc = true
            case 0x0d, 0x0a:                       // Enter
                emit("\r\n")
                let s = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                line.removeAll()
                if !s.isEmpty {
                    emit("\(dim)demo:\(reset) ‘\(s)’ needs a real Mac.\r\n")
                }
                prompt()
            case 0x7f, 0x08:                       // backspace
                if !line.isEmpty { line.removeLast(); emit("\u{8} \u{8}") }
            case 0x20...0x7e:                      // printable → echo
                line.append(b); emit(String(UnicodeScalar(b)))
            default:
                break
            }
        }
        return true
    }

    func resize(cols: Int, rows: Int) {}
    func requestRedraw() {}
    var onScreen: ((ArraySlice<UInt8>) -> Void)?
    func requestSnapshot() {}   // the demo screen is already whatever we scripted
    func putClipboard(_ image: Data) -> Bool { true }
    var onUnsent: ((Outbound, Bool) -> Void)?   // nothing leaves the phone, nothing comes back
    func close() { cont.finish() }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
