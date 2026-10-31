import SwiftUI
import UIKit

/// #646: a chat with the Mac's local model, one reply at a time. Each reply streams over a
/// connection of its own; Stop closes it, and the Mac stops with it.
/// ponytail: in memory only, gone with the sheet; save chats once someone asks for them.
@MainActor
final class ChatSession: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var prompt: String
        var reply = ""
        var end: End = .streaming
    }

    enum End: Equatable { case streaming, done, stopped, failed(String) }

    /// The Mac's cap on all contents together, in UTF-8 bytes ("too long" past it).
    static let limit = 262_144

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var model: LocalModel?
    /// The newest message alone is over `limit`: said inline, nothing sent.
    @Published var tooLong = false
    private let transport: SessionTransport
    private var task: Task<Void, Never>?

    init(transport: SessionTransport) { self.transport = transport }

    var generating: Bool { turns.last?.end == .streaming }

    /// A failed read keeps what was known: the title falls back to "Chat", the wait to dots.
    func loadModel() async {
        if let m = try? await transport.models() { model = m.first }
    }

    /// False, the draft kept, when nothing went.
    @discardableResult func send(_ text: String) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !generating else { return false }
        guard let messages = Self.fit(Self.history(turns[...]), prompt) else { tooLong = true; return false }
        tooLong = false
        turns.append(Turn(prompt: prompt))
        start(messages)
        return true
    }

    /// The same conversation again, the failed reply's partial text dropped.
    func retry() {
        guard let i = turns.indices.last, case .failed = turns[i].end,
              let messages = Self.fit(Self.history(turns.dropLast()), turns[i].prompt) else { return }
        turns[i].reply = ""
        turns[i].end = .streaming
        start(messages)
    }

    /// The partial reply stays, marked stopped.
    func stop() {
        task?.cancel()
        task = nil
        if let id = turns.last?.id { settle(id, .stopped) }
    }

    func clear() {
        stop()
        turns = []
        tooLong = false
    }

    private func start(_ messages: [ChatMessage]) {
        let id = turns[turns.count - 1].id
        // The Mac unloads its model 5 minutes after the last chat: re-read `loaded` for the wait.
        Task { await loadModel() }
        let stream = transport.chat(messages)
        task = Task { [weak self] in
            do {
                for try await text in stream { self?.append(text, id) }
                self?.settle(id, .done)
            } catch {
                self?.settle(id, .failed(Self.copy(error.localizedDescription)))
            }
        }
    }

    private func append(_ text: String, _ id: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == id }), turns[i].end == .streaming else { return }
        turns[i].reply += text
        model?.loaded = true   // a delta means it is resident
    }

    /// Only a turn still streaming ends: a Stop is never overwritten by the stream's own end.
    private func settle(_ id: UUID, _ end: End) {
        guard let i = turns.firstIndex(where: { $0.id == id }), turns[i].end == .streaming else { return }
        turns[i].end = end
    }

    /// The finished turns as user and assistant pairs, so roles always alternate; a turn with
    /// no reply (failed before a word) is left out.
    static func history(_ turns: ArraySlice<Turn>) -> [ChatMessage] {
        turns.filter { !$0.reply.isEmpty }.flatMap {
            [ChatMessage(role: .user, content: $0.prompt), ChatMessage(role: .assistant, content: $0.reply)]
        }
    }

    /// `history` plus `prompt`, the oldest pairs dropped until every content fits `limit`;
    /// nil when `prompt` alone doesn't.
    static func fit(_ history: [ChatMessage], _ prompt: String) -> [ChatMessage]? {
        guard prompt.utf8.count <= limit else { return nil }
        var total = history.reduce(prompt.utf8.count) { $0 + $1.content.utf8.count }
        var kept = history[...]
        while total > limit, !kept.isEmpty {
            total -= kept.prefix(2).reduce(0) { $0 + $1.content.utf8.count }
            kept = kept.dropFirst(2)
        }
        return kept + [ChatMessage(role: .user, content: prompt)]
    }

    /// The two busy refusals and an over-long context in plain words; every other error as the
    /// Mac wrote it. The context one carries token counts, so it matches by its fixed parts.
    static func copy(_ message: String) -> String {
        switch message {
        case "busy: another chat is running": "Another chat is running on the Mac. Try again when it finishes."
        case "busy: the Mac's agent is running": "The Mac's agent is working. Try again in a moment."
        case _ where message.hasPrefix("inference error: agent prompt") && message.contains("exceeds the context window"):
            "This chat is too long for the Mac's model. Start a new chat."
        default: message
        }
    }
}

/// #646: the ⋯ menu's Chat sheet. Titled with the Mac's model, else "Chat".
struct ChatScreen: View {
    @StateObject private var chat: ChatSession
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    init(chat: ChatSession) {
        _chat = StateObject(wrappedValue: chat)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.turns.isEmpty {
                            Text("Ask the AI model on your Mac. It runs there, privately.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(chat.turns) { turn in
                            TurnView(turn: turn, cold: chat.model?.loaded == false,
                                     retry: turn.id == chat.turns.last?.id ? { chat.retry() } : nil)
                        }
                        Text("The model unloads from the Mac 5 minutes after your last chat.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .id("end")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.turns) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle(chat.model?.name ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { chat.clear(); draft = "" } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New Chat")
                        .disabled(chat.turns.isEmpty)
                }
            }
        }
        .task { await chat.loadModel() }
        .onDisappear { chat.stop() }   // closing the sheet stops the Mac too
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chat.tooLong {
                Text("This message is too long for the Mac's model. Shorten it to send.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                if chat.generating {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                        .accessibilityLabel("Stop")
                } else {
                    Button { if chat.send(draft) { draft = "" } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .accessibilityLabel("Send")
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: draft) { _ in chat.tooLong = false }
    }
}

/// One prompt, its reply or the wait for it, and how it ended.
private struct TurnView: View {
    let turn: ChatSession.Turn
    let cold: Bool          // the Mac said its model isn't loaded
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Bubble(text: turn.prompt, mine: true)
            if !turn.reply.isEmpty {
                Bubble(text: turn.reply, mine: false)
            } else if turn.end == .streaming {
                if cold {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading the model on the Mac — the first reply can take 30 seconds or more")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TypingDots()
                }
            }
            switch turn.end {
            case .stopped:
                Text("Stopped").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(message).font(.footnote).foregroundStyle(.red)
                    if let retry { Button("Retry", action: retry).font(.footnote.bold()) }
                }
            case .streaming, .done:
                EmptyView()
            }
        }
    }
}

/// Long-press copies the message. The model's text renders inline markdown, plain when that
/// doesn't parse.
private struct Bubble: View {
    let text: String
    let mine: Bool

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(mine ? Color.white : Color.primary)
            .background(mine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .contextMenu {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    @ViewBuilder private var content: some View {
        if !mine, let md = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(md)
        } else {
            Text(text)
        }
    }
}

/// The wait for a resident model's first word.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let lit = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().frame(width: 7, height: 7).opacity(i == lit ? 1 : 0.3)
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("The Mac is writing")
    }
}
