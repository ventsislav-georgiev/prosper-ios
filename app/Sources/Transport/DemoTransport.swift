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
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream { DemoStream() }
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream { DemoStream() }
    func kill(name: String) async throws {}
    func rename(name: String, alias: String?) async throws {}
}

final class DemoStream: TerminalStream {
    let output: AsyncStream<ArraySlice<UInt8>>
    private let cont: AsyncStream<ArraySlice<UInt8>>.Continuation
    private var line: [UInt8] = []

    // Neon palette (matches the Prosper theme): cyan + bright blue.
    private let cyan = "\u{1b}[38;2;33;204;255m"
    private let blue = "\u{1b}[38;2;117;235;255m"
    private let dim = "\u{1b}[38;2;120;140;160m"
    private let reset = "\u{1b}[0m"

    init() {
        var c: AsyncStream<ArraySlice<UInt8>>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        cont = c
        Task { await play() }
    }

    private func emit(_ s: String) { cont.yield(ArraySlice(Array(s.utf8))) }
    private func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    private func prompt() { emit("\(cyan)prosper@demo\(reset):\(blue)~\(reset) $ ") }

    /// Type `s` at a fresh prompt, char-by-char, then newline.
    private func typeLine(_ s: String) async {
        prompt()
        for ch in s { emit(String(ch)); await pause(26) }
        emit("\r\n")
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
