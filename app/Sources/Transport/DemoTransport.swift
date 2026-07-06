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
        [DchSession(name: "demo", alias: "Demo session"),
         DchSession(name: "claude", alias: "claude (sample)")]
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

    // MARK: - Claude Code look-alike

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
        emit("\(dim)\u{2234} ")            // ∴
        await streamWords("\(s)\(reset)", 20)
        emit("\r\n\r\n")
    }
    private func bullet(_ s: String) async {
        emit("\(white)\u{25cf}\(reset) ")  // ●
        await streamWords(s, 18)
        emit("\r\n")
    }
    private func toolOut(_ s: String) { emit("\(dim)  \u{2514}\(reset)  \(s)\r\n") }  // └

    private func playClaude() async {
        emit("\u{1b}[2J\u{1b}[H")
        await pause(300)
        diffAdd(13, "was armed, so the paired phone never showed the wake-ready badge and couldn't actually wake")
        diffAdd(14, "the Mac. The toggle read your sign-in from a background task that could come back empty even")
        diffAdd(15, "while the app showed you signed in; it now reads it on the main thread and reuses that")
        diffAdd(16, "session when publishing state to the server, so a single toggle both arms the daemon and")
        diffAdd(17, "advertises the cadence the phone displays.")
        diffAdd(18, "- Adds temporary diagnostic logging around the wake toggle (visible in Console) to confirm the")
        diffAdd(19, "fix on real hardware; it will be removed once verified.")
        diffAdd(20, "")
        diffCtx(21, "## v2.115.0-beta.3")
        diffCtx(22, "")
        diffCtx(23, "### Appearance")
        emit("\r\n")
        await pause(500)
        await narrator("Now I'm committing and pushing these changes, then releasing them since the build already passed.")
        await bullet("Build already green (exit 0). Commit + push + cut beta.")
        emit("\r\n")
        await bullet("\(white)Bash\(reset)(git add CHANGELOG.swift && git commit -m \"fix(remote-wake)…\")")
        toolOut("\(blue)72064e5\(reset) fix(remote-wake): load sign-in on main thread")
        emit("\r\n")
        await bullet("\(white)Bash\(reset)(git push origin main)")
        toolOut("To github.com:ventsislav-georgiev/prosper.git")
        toolOut("   2484a36..72064e5  main \u{2192} main")
        emit("\r\n")
        await bullet("\(white)Bash\(reset)(scripts/release.sh beta)")
        toolOut("Releasing v2.115.0-beta.4 (from v2.114.3)")
        toolOut(" * [new tag]   v2.115.0-beta.4 \u{2192} v2.115.0-beta.4")
        emit("\r\n")
        await pause(300)
        await narrator("The tag's been pushed and CI will handle the build, signing, and notarization now.")
        await bullet("Shipped. \(white)v2.115.0-beta.4\(reset) tagged + pushed; release.yml building/signing/notarizing now.")
        emit("\r\n\(dim)\u{2731} Cooked for 3m 32s\(reset)\r\n")                          // ✱
        emit("\(dim)            Image in clipboard \u{00b7} ctrl+v to paste\(reset)\r\n\r\n")
        await pause(300)
        // Claude Code bottom chrome (input box + status line) — frozen frame.
        let orange = "\u{1b}[38;2;255;170;60m"
        emit("\(blue)\u{203a}\(reset) \(dim)Watch the release build\(reset)\r\n\r\n")
        emit("\(white)[OMC#4.15.0L]\(dim) | Model: \(cyan)Opus 4.8\(reset)\r\n")
        emit("\(dim)5h:\(green)7%\(dim)(4h44m) wk:\(green)36%\(dim)(4d22h) sn:\(green)0%\(dim)(4d22h)\(reset)\r\n")
        emit("\(dim)session:\(orange)4481m\(dim) | ctx:\(green)6%\(dim) | \u{1f527}153\(reset)\r\n")
        emit("\(orange)\u{25b6}\u{25b6} auto mode on\(dim) (shift+tab to cycle) \u{00b7} \u{2190} for \u{2026}\(reset)\r\n")
    }

    private func play() async {
        emit("\u{1b}[2J\u{1b}[H")  // clear + home
        emit("\(cyan)  Prosper · Remote Terminal\(reset) \(dim)— demo session\(reset)\r\n")
        emit("\(dim)  Your Mac's dch sessions, attached over Tailscale. No passwords.\(reset)\r\n\r\n")
        await pause(450)
        await typeLine("ls ~/projects")
        emit("bookplay   notes.md   prosper   scripts   \(blue)dchterm\(reset)\r\n")
        await pause(350)
        await typeLine("uname -msr")
        emit("Darwin 25.5.0 arm64\r\n")
        await pause(300)
        await typeLine("echo \"runs the same session as your desktop\"")
        emit("runs the same session as your desktop\r\n")
        await pause(250)
        emit("\r\n\(dim)  Try typing below — connect a real machine to run live commands.\(reset)\r\n\r\n")
        prompt()
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        for b in bytes {
            switch b {
            case 0x0d, 0x0a:                       // Enter
                emit("\r\n")
                let s = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                line.removeAll()
                if !s.isEmpty {
                    emit("\(dim)demo:\(reset) ‘\(s)’ — connect a real machine to run this.\r\n")
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
    }

    func resize(cols: Int, rows: Int) {}
    func requestRedraw() {}
    func close() { cont.finish() }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
