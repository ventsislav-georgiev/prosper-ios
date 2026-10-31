import SwiftUI
import AVFAudio
import Speech

/// Prosper's side of the keyboards' speech-to-text (#598). A keyboard can't record, and an app
/// can start the mic only in the foreground, so the keyboard's mic key opens Prosper
/// (`prosper://dictate?id=`): it starts the mic here, keeps it running in the background
/// (`UIBackgroundModes` audio) for the ready period after the last dictation, with the orange
/// dot showing, and the keyboard drives it over the App Group (`Dictation`). Apple's engine,
/// on the device, in English: `SpeechTranscriber`, or `DictationTranscriber` where the
/// hardware lacks it. A call, Siri or a route change ends it; the next tap opens Prosper again.
///
/// ponytail: a fresh analyzer per dictation (the model stays loaded, `processLifetime`); keep
/// one running between dictations if its start lag shows on a device.
@MainActor
final class DictationService: ObservableObject {
    static let shared = DictationService()

    /// The screen (`DictationScreen`): opened by the keyboard's link, closed by Stop.
    @Published var showing = false
    /// What the keyboards read, as last written; nil before the first dictation.
    @Published private(set) var state: Dictation.State?
    /// Permissions and the model's download, while they hold up the start.
    @Published private(set) var status: String?

    var warm: Bool { state.map { $0.phase != .off } ?? false }

    private let store = Dictation.Store.shared()
    private let engine = AVAudioEngine()
    private let feed = Feed()
    private var pings: DarwinPings?
    private var beat: Timer?
    /// The ready period counts from the last dictation's end, or the mic's start.
    private var lastUse = Date()
    private var heardAt = Date()
    /// The running `Transcription` (iOS 26).
    private var transcription: AnyObject?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DictationService.shared.takePending() }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let began = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in if began { DictationService.shared.end("The mic stopped for a call or Siri — tap it to reopen Prosper") } }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            // ponytail: a route change (headphones in or out) that stopped the engine ends it;
            // restart it in the foreground if that bites.
            Task { @MainActor in
                let me = DictationService.shared
                if !me.engine.isRunning, me.state?.phase != .preparing { me.end("The audio route changed — tap the mic to reopen Prosper") }
            }
        }
    }

    /// `prosper://dictate?id=`: the screen, and listening for that request at once.
    func open(_ url: URL) -> Bool {
        guard let id = Dictation.id(from: url) else { return false }
        showing = true
        start(id)
        return true
    }

    /// Stop: the mic off now, the screen closed. Needs no keyboard.
    func stop() {
        end(nil)
        showing = false
    }

    /// The keyboard's request when Prosper was opened by hand after its hop failed.
    private func takePending() {
        guard !warm, let r = store?.request, abs(r.date.timeIntervalSinceNow) < Dictation.leftover,
              store?.state?.id != r.id else { return }
        showing = true
        start(r.id)
    }

    private func start(_ id: UUID) {
        guard !(warm && state?.id == id), #available(iOS 26, *) else { return }
        Task { await begin(id) }
    }

    @available(iOS 26, *)
    private func begin(_ id: UUID) async {
        halt()
        write(Dictation.State(id: id, phase: .preparing, heartbeat: Date()))
        keepAlive()
        status = "Asking for the microphone…"
        guard await AVAudioApplication.requestRecordPermission() else {
            return end("Microphone access is off — allow it in Settings › Prosper")
        }
        guard await withCheckedContinuation({ c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }) == .authorized else {
            return end("Speech Recognition is off — allow it in Settings › Prosper")
        }
        do {
            let t = try await Transcription.start(feed: feed, status: { [weak self] in self?.status = $0 },
                                                  heard: { [weak self] in self?.heard($0, final: $1) })
            transcription = t
            guard state?.id == id, warm else { return halt() }   // ended or replaced meanwhile
            if !engine.isRunning { try startMic() }
            heardAt = Date()
            status = nil
            update { $0.phase = .listening }
        } catch {
            end("The mic couldn't start: \(error.localizedDescription)")
        }
    }

    private func startMic() throws {
        let session = AVAudioSession.sharedInstance()
        // Mixable, so music plays on; the speaker, not the earpiece, for what plays.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0), block: Self.tap(feed))
        engine.prepare()
        try engine.start()
        lastUse = Date()
    }

    /// Built off the main actor: the block runs on the audio thread.
    nonisolated private static func tap(_ feed: Feed) -> AVAudioNodeTapBlock { { buffer, _ in feed.push(buffer) } }

    /// The heartbeat, the ready period, and the keyboards' pings, while the mic is on.
    private func keepAlive() {
        if pings == nil {
            pings = DarwinPings([.start, .stop, .cancel]) { [weak self] in self?.ping($0) }
        }
        if beat == nil {
            beat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in DictationService.shared.tick() }
            }
        }
    }

    private func ping(_ p: Dictation.Ping) {
        switch p {
        case .start: if let id = store?.request?.id { start(id) }
        case .stop: Task { await finish(cancel: false) }
        case .cancel: Task { await finish(cancel: true) }
        case .changed: break
        }
    }

    private func tick() {
        guard let s = state, s.phase != .off else { return }
        let period = Dictation.ReadyPeriod.stored()
        if s.phase == .listening, Date().timeIntervalSince(heardAt) >= Dictation.quiet {
            Task { await finish(cancel: false) }
        } else if s.phase == .ready, period.expired(since: lastUse, now: Date()) {
            return end(nil)
        }
        update { $0.heartbeat = Date() }
    }

    /// Done (the last phrase finalized and kept) or ✕ (the tail dropped); the mic stays ready.
    private func finish(cancel: Bool) async {
        guard #available(iOS 26, *), let t = transcription as? Transcription else { return }
        transcription = nil
        feed.detach()
        let id = state?.id
        if !cancel { update { $0.phase = .finishing } }
        await t.halt(cancel: cancel)
        guard state?.id == id, state?.phase == .listening || state?.phase == .finishing else { return }
        update { s in
            if !cancel, !s.tail.isEmpty { s.phrases.append(s.tail) }   // no final came: the tail as heard
            s.tail = ""
            s.phase = .ready
        }
        lastUse = Date()
    }

    private func heard(_ text: String, final: Bool) {
        guard let s = state, s.phase == .listening || s.phase == .finishing else { return }
        heardAt = Date()
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update { s in
            if final {
                if !words.isEmpty { s.phrases.append(words) }
                s.tail = ""
            } else {
                s.tail = words
            }
        }
    }

    /// The mic off, the session given back, the keyboards told (`note`, the reason shown).
    func end(_ note: String?) {
        guard warm else { return }
        halt()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        beat?.invalidate()
        beat = nil
        pings = nil
        status = nil
        update { s in
            s.phase = .off
            s.tail = ""
            s.note = note
        }
    }

    /// The running dictation dropped: its input cut here, at once, so a late stop never cuts
    /// the next one's.
    private func halt() {
        feed.detach()
        if #available(iOS 26, *), let t = transcription as? Transcription { Task { await t.halt(cancel: true) } }
        transcription = nil
    }

    private func update(_ change: (inout Dictation.State) -> Void) {
        guard var s = state else { return }
        change(&s)
        write(s)
    }

    private func write(_ s: Dictation.State) {
        state = s
        store?.state = s
        DarwinPings.post(.changed)
    }
}

extension Dictation {
    /// How long Prosper keeps the mic ready after the last dictation (Settings › Dictation).
    enum ReadyPeriod: Int, CaseIterable, Identifiable {
        case two = 2, ten = 10, thirty = 30, untilStopped = 0
        static let key = "dictation.readyMinutes"
        var id: Int { rawValue }

        /// The stored choice; absent or unknown reads as `.ten`, the Settings default.
        static func stored(in defaults: UserDefaults = .standard) -> ReadyPeriod {
            (defaults.object(forKey: key) as? Int).flatMap(ReadyPeriod.init) ?? .ten
        }
        var title: String { self == .untilStopped ? "Until Stopped" : "\(rawValue) min" }

        func expired(since: Date, now: Date) -> Bool {
            self != .untilStopped && now.timeIntervalSince(since) >= TimeInterval(rawValue) * 60
        }
    }
}

/// The mic tap's side, on the audio thread: buffers go on only while a dictation listens,
/// converted to the analyzer's format.
private final class Feed: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?

    func attach(_ format: AVAudioFormat?, _ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.withLock { self.format = format; self.sink = sink; converter = nil }
    }

    func detach() { lock.withLock { sink = nil } }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let sink else { return }
        guard let format, format != buffer.format else { return sink(buffer) }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        let frames = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { sink(out) }
    }
}

/// One dictation's analyzer, its input, and the reader of its results.
@available(iOS 26, *)
private final class Transcription {
    let analyzer: SpeechAnalyzer
    let input: AsyncStream<AnalyzerInput>.Continuation
    let reader: Task<Void, Never>

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, reader: Task<Void, Never>) {
        self.analyzer = analyzer
        self.input = input
        self.reader = reader
    }

    /// The user's English if the engine has it, else US English; its model installed first.
    @MainActor
    static func start(feed: Feed, status: @escaping (String?) -> Void,
                      heard: @escaping (String, Bool) -> Void) async throws -> Transcription {
        let want = Locale(identifier: Dictation.english(Locale.preferredLanguages))
        let module: any SpeechModule
        let reader: Task<Void, Never>
        if SpeechTranscriber.isAvailable {
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: want) ?? Locale(identifier: "en-US")
            let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            module = t
            reader = Task { @MainActor in
                do { for try await r in t.results { heard(String(r.text.characters), r.isFinal) } } catch {}
            }
        } else {
            let locale = await DictationTranscriber.supportedLocale(equivalentTo: want) ?? Locale(identifier: "en-US")
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
            module = t
            reader = Task { @MainActor in
                do { for try await r in t.results { heard(String(r.text.characters), r.isFinal) } } catch {}
            }
        }
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let progress = Task { @MainActor in
                    while !Task.isCancelled {
                        status("Downloading the English speech model… \(Int(install.progress.fractionCompleted * 100))%")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                defer { progress.cancel() }
                try await install.downloadAndInstall()
            }
            status("Starting the mic…")
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            feed.attach(format) { input.yield(AnalyzerInput(buffer: $0)) }
            return Transcription(analyzer: analyzer, input: input, reader: reader)
        } catch {
            reader.cancel()
            throw error
        }
    }

    /// Done: what was heard finalized, its last results read. ✕: dropped at once. The feed is
    /// the caller's to detach first.
    func halt(cancel: Bool) async {
        input.finish()
        if cancel {
            await analyzer.cancelAndFinishNow()
            reader.cancel()
        } else {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await reader.value
        }
    }
}

/// The screen the keyboard's mic key opens (#598): listening at once, the way back named,
/// what's heard, and Stop, which turns the mic off without the keyboard.
struct DictationScreen: View {
    @ObservedObject var service: DictationService

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch service.state?.phase {
                case .preparing?, .listening?, .finishing?:
                    Label("Listening — tap ◀ Back to return", systemImage: "mic.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.red)
                    Text("Keep talking: the Prosper keyboard types what you say.")
                        .foregroundStyle(.secondary)
                case .ready?:
                    Label("The mic is ready", systemImage: "mic")
                        .font(.title2.weight(.semibold))
                    Text("Tap the Prosper keyboard's mic in any app to dictate. Settings › Dictation sets how long the mic stays ready.")
                        .foregroundStyle(.secondary)
                case .off?, nil:
                    Label("The mic is off", systemImage: "mic.slash")
                        .font(.title2.weight(.semibold))
                    if let note = service.state?.note { Text(note).foregroundStyle(.secondary) }
                }
                if let status = service.status { Text(status).font(.callout).foregroundStyle(.secondary) }
                if let s = service.state, service.warm {
                    ScrollView {
                        Text((s.phrases + [s.tail]).joined(separator: " "))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer()
                Button(role: .destructive) { service.stop() } label: {
                    Label(service.warm ? "Stop the Mic" : "Close", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("Dictation")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
