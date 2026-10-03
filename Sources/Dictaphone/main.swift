import AppKit
import FluidAudio
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import WhisperKit

// Dictaphone: ⌘D records/stops, transcripts are saved, copied, and can be read
// back with the built-in macOS voices (⌥⌘D reads the latest).

func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let url = URL(fileURLWithPath: "/tmp/dictaphone.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

// MARK: - Model

struct Turn: Codable {
    var speaker: Int
    var text: String
    var start: Float? = nil   // seconds from the start of the recording
}

struct MeetingInfo: Codable {
    var title: String
    var duration: Double
}

func clock(_ seconds: Double) -> String {
    let t = Int(seconds), h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

struct Transcript: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var text: String
    var turns: [Turn]? = nil              // present when speakers were detected
    var names: [String: String]? = nil    // speaker number → custom name
    var meeting: MeetingInfo? = nil       // present for meeting-mode recordings

    var speakerCount: Int { Set((turns ?? []).map(\.speaker)).count }

    func name(_ speaker: Int) -> String { names?[String(speaker)] ?? "Person \(speaker)" }

    /// Text with "Name: …" labels when speakers were detected; used for display, copy and read-back.
    var displayText: String {
        guard let turns else { return text }
        return turns.map { "\(name($0.speaker)): \($0.text)" }.joined(separator: "\n")
    }

    /// Markdown export: meetings get a header and timestamped lines; other transcripts are plain text.
    var markdown: String {
        guard let m = meeting else { return displayText }
        var out = "# \(m.title)\n\n*\(date.formatted(date: .long, time: .shortened)) · \(clock(m.duration)) · \(speakerCount) speaker\(speakerCount == 1 ? "" : "s")*\n\n"
        out += "## Transcript\n\n"
        out += (turns ?? []).map { "**[\(clock(Double($0.start ?? 0)))] \(name($0.speaker)):** \($0.text)" }.joined(separator: "\n\n")
        return out
    }
}

final class Store: ObservableObject {
    @Published var items: [Transcript] = []          // newest first
    @Published var status = "Loading model…"
    @Published var spinning = false
    @Published var recording = false
    var onTestSystemAudio: () -> Void = {}
    @Published var voiceID: String { didSet { UserDefaults.standard.set(voiceID, forKey: "voiceID") } }
    @Published var speed: Double { didSet { UserDefaults.standard.set(speed, forKey: "speed") } }
    @Published var autoRead: Bool { didSet { UserDefaults.standard.set(autoRead, forKey: "autoRead") } }
    @Published var captureMode: String { didSet { UserDefaults.standard.set(captureMode, forKey: "captureMode") } }
    @Published var detectSpeakers: Bool { didSet { UserDefaults.standard.set(detectSpeakers, forKey: "detectSpeakers") } }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictaphone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcripts.json")
    }()

    init() {
        let d = UserDefaults.standard
        voiceID = d.string(forKey: "voiceID") ?? ""
        speed = d.object(forKey: "speed") as? Double ?? 1.0
        autoRead = d.bool(forKey: "autoRead")
        detectSpeakers = d.bool(forKey: "detectSpeakers")
        captureMode = d.string(forKey: "captureMode") ?? CaptureMode.both.rawValue
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Transcript].self, from: data) { items = saved }
    }

    func rename(_ id: UUID, speaker: Int, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = items[i].names ?? [:]
        if n.isEmpty { names.removeValue(forKey: String(speaker)) } else { names[String(speaker)] = n }
        items[i].names = names
        save()
    }

    func add(_ text: String, turns: [Turn]? = nil, meeting: MeetingInfo? = nil, names: [String: String]? = nil) -> Transcript {
        let t = Transcript(date: Date(), text: text, turns: turns, names: names, meeting: meeting)
        items.insert(t, at: 0)
        save()
        return t
    }

    func delete(_ t: Transcript) { items.removeAll { $0.id == t.id }; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL) }
    }
}

// MARK: - Speech

final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var kokoro: KokoroAneManager?
    private var player: AVAudioPlayer?
    private var generation = 0   // invalidates in-flight neural synthesis on stop
    private var queue: [Transcript] = []
    private let store: Store
    @Published var currentID: UUID?
    @Published var range: NSRange?

    init(store: Store) {
        self.store = store
        super.init()
        synth.delegate = self
    }

    func speak(_ items: [Transcript]) {
        stop()
        queue = items
        next()
    }

    func stop() {
        queue = []
        generation += 1
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
        currentID = nil
        range = nil
    }

    private func next() {
        guard !queue.isEmpty else { currentID = nil; range = nil; return }
        let t = queue.removeFirst()
        currentID = t.id
        range = nil
        if store.voiceID.hasPrefix(Speaker.kokoroPrefix) {
            speakNeural(t, voice: String(store.voiceID.dropFirst(Speaker.kokoroPrefix.count)))
            return
        }
        let u = AVSpeechUtterance(string: t.displayText)
        u.voice = store.voiceID.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: store.voiceID)
        u.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * Float(store.speed),
                         AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        synth.speak(u)
    }

    // MARK: Neural (Kokoro, on-device)
    static let kokoroPrefix = "kokoro:"
    static let kokoroVoices: [(id: String, name: String)] = {
        let names = ["heart": "Heart", "bella": "Bella", "nicole": "Nicole", "sarah": "Sarah", "sky": "Sky",
                     "alloy": "Alloy", "aoede": "Aoede", "jessica": "Jessica", "kore": "Kore", "nova": "Nova",
                     "river": "River"]
        return KokoroAneConstants.englishVoices
            .filter { ["af_", "am_", "bf_", "bm_"].contains(where: $0.hasPrefix) }
            .map { id in
                let parts = id.split(separator: "_")
                let accent = id.hasPrefix("a") ? "US" : "UK"
                let gender = id.dropFirst().first == "f" ? "female" : "male"
                let n = names[String(parts[1])] ?? String(parts[1]).capitalized
                return (id, "\(n) — \(accent) \(gender)")
            }
    }()

    private func speakNeural(_ t: Transcript, voice: String) {
        generation += 1
        let gen = generation
        let speed = Float(store.speed)
        store.status = kokoro == nil ? "Loading neural voice (first use downloads ~350 MB)…" : "Generating speech…"
        store.spinning = true
        Task {
            do {
                if self.kokoro == nil {
                    let m = KokoroAneManager(variant: .english)
                    try await m.initialize()
                    self.kokoro = m
                }
                let wav = try await self.kokoro!.synthesize(text: t.displayText, voice: voice, speed: speed)
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.store.spinning = false
                    self.store.status = "Reading aloud…"
                    do {
                        let p = try AVAudioPlayer(data: wav)
                        p.delegate = self
                        self.player = p
                        p.play()
                    } catch { self.fail("Playback failed: \(error.localizedDescription)") }
                }
            } catch {
                log("kokoro failed: \(error)")
                await MainActor.run { if gen == self.generation { self.fail("Neural voice failed: \(error.localizedDescription)") } }
            }
        }
    }

    func unloadNeural() { stop(); kokoro = nil }

    private func fail(_ msg: String) {
        store.spinning = false
        store.status = msg
        queue = []
        currentID = nil
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        DispatchQueue.main.async {
            guard p === self.player else { return }
            self.player = nil
            self.store.status = "Ready"
            self.next()
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.range = r }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.next() }
    }

    static func voices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium: q = " (Premium)"
        case .enhanced: q = " (Enhanced)"
        default: q = ""
        }
        return "\(v.name)\(q) — \(v.language)"
    }
}

// MARK: - Downloaded models

struct ModelEntry: Identifiable {
    var id: String { title }
    let title: String
    let detail: String
    let paths: [URL]
    let bytes: Int64
}

final class ModelManager: ObservableObject {
    @Published var entries: [ModelEntry] = []
    var onNeuralRemoved: () -> Void = {}
    var onSpeakerRemoved: () -> Void = {}

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var whisperRoot: URL { home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml") }
    private var kokoroRoot: URL { home.appendingPathComponent(".cache/fluidaudio/Models") }

    func refresh() {
        let fm = FileManager.default
        var out: [ModelEntry] = []
        let whisper = (try? fm.contentsOfDirectory(at: whisperRoot, includingPropertiesForKeys: nil)) ?? []
        for dir in whisper.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.hasDirectoryPath {
            let name = dir.lastPathComponent.replacingOccurrences(of: "openai_whisper-", with: "")
            out.append(ModelEntry(title: "Speech recognition — Whisper \(name)",
                                  detail: "Transcribes your voice. Re-downloads on next launch if removed.",
                                  paths: [dir], bytes: Self.size(dir)))
        }
        let kokoro = ["kokoro", "kokoro-82m-coreml"].map { kokoroRoot.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        if !kokoro.isEmpty {
            out.append(ModelEntry(title: "Neural voices — Kokoro",
                                  detail: "Natural read-back voices. Re-downloads next time you pick one.",
                                  paths: kokoro, bytes: kokoro.reduce(0) { $0 + Self.size($1) }))
        }
        let diar = home.appendingPathComponent("Library/Application Support/FluidAudio/Models/speaker-diarization-coreml")
        if fm.fileExists(atPath: diar.path) {
            out.append(ModelEntry(title: "Speaker detection — diarizer",
                                  detail: "Works out who is talking. Re-downloads next time you detect speakers.",
                                  paths: [diar], bytes: Self.size(diar)))
        }
        entries = out
    }

    func remove(_ e: ModelEntry) {
        for p in e.paths { try? FileManager.default.removeItem(at: p) }
        if e.title.hasPrefix("Neural") { onNeuralRemoved() }
        if e.title.hasPrefix("Speaker") { onSpeakerRemoved() }
        refresh()
    }

    static func size(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

struct ModelsView: View {
    @ObservedObject var models: ModelManager
    @Environment(\.dismiss) var dismiss
    @State private var pending: ModelEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloaded models").font(.title3.bold())
            if models.entries.isEmpty {
                Text("No models downloaded yet.").foregroundStyle(.secondary)
            }
            ForEach(models.entries) { e in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.headline)
                        Text(e.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ModelManager.fmt(e.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.activateFileViewerSelecting(e.paths) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                    Button(role: .destructive) { pending = e } label: { Image(systemName: "trash") }
                        .help("Remove")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            Divider()
            HStack {
                Text("Total: \(ModelManager.fmt(models.entries.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 500)
        .onAppear { models.refresh() }
        .confirmationDialog("Remove \(pending?.title ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Remove (\(ModelManager.fmt(pending?.bytes ?? 0)))", role: .destructive) {
                if let e = pending { models.remove(e) }
                pending = nil
            }
        } message: { Text(pending?.detail ?? "") }
    }
}

// MARK: - Views

struct CardView: View {
    let t: Transcript
    @ObservedObject var store: Store
    @ObservedObject var speaker: Speaker
    @State private var renaming: Int?
    @State private var newName = ""
    @State private var showTranscript = false

    var speaking: Bool { speaker.currentID == t.id }

    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let m = t.meeting {
                    Label(m.title, systemImage: "person.3.fill").font(.headline)
                } else {
                    Text(t.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { speaking ? speaker.stop() : speaker.speak([t]) } label: {
                    Image(systemName: speaking ? "stop.fill" : "play.fill")
                }.help(speaking ? "Stop" : "Read aloud")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(t.markdown, forType: .string)
                    store.status = "Copied to clipboard"
                } label: { Image(systemName: "doc.on.doc") }.help(t.meeting != nil ? "Copy as Markdown" : "Copy")
                if t.meeting != nil {
                    Button(action: export) { Image(systemName: "square.and.arrow.up") }.help("Save as Markdown file…")
                }
                Button { if speaking { speaker.stop() }; store.delete(t) } label: {
                    Image(systemName: "trash")
                }.help("Delete")
            }
            .buttonStyle(.borderless)

            if let m = t.meeting {
                meetingBody(m)
            } else {
                if let turns = t.turns, !speaking {
                    turnsView(turns, showTime: false)
                } else {
                    Text(highlighted).textSelection(.enabled).font(.body)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(speaking ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(speaking ? Color.accentColor : .clear, lineWidth: 1.5))
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let r = renaming { store.rename(t.id, speaker: r, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("Renames this speaker throughout this transcript. Leave blank to reset.") }
    }

    @ViewBuilder func meetingBody(_ m: MeetingInfo) -> some View {
        Text("\(t.date.formatted(date: .abbreviated, time: .shortened)) · \(clock(m.duration)) · \(t.speakerCount) speaker\(t.speakerCount == 1 ? "" : "s")")
            .font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("Full transcript", isExpanded: $showTranscript) {
            turnsView(t.turns ?? [], showTime: true).padding(.top, 6)
        }
    }

    @ViewBuilder func turnsView(_ turns: [Turn], showTime: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                let color = Self.palette[(turn.speaker - 1) % Self.palette.count]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if showTime, let st = turn.start {
                        Text(clock(Double(st))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button { newName = t.name(turn.speaker); renaming = turn.speaker } label: {
                        Text(t.name(turn.speaker)).font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(color.opacity(0.2)))
                            .foregroundStyle(color)
                    }.buttonStyle(.plain).help("Click to rename")
                    Text(turn.text).textSelection(.enabled)
                }
            }
        }
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (t.meeting?.title ?? "Meeting").replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? t.markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var highlighted: AttributedString {
        var a = AttributedString(t.displayText)
        if speaking, t.meeting == nil, let r = speaker.range, let rr = Range(r, in: a) {
            a[rr].backgroundColor = .yellow.opacity(0.5)
            a[rr].foregroundColor = .black
        }
        return a
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @ObservedObject var speaker: Speaker
    @ObservedObject var models: ModelManager
    @State private var showModels = false
    let voices = Speaker.voices()

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic.circle").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Press ⌘D to record").font(.headline)
                    Text("Press ⌘D again to stop and transcribe").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.items) { CardView(t: $0, store: store, speaker: speaker) }
                    }.padding(12)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Voice", selection: $store.voiceID) {
                        Text("System default").tag("")
                        Section("Neural (Kokoro, on-device)") {
                            ForEach(Speaker.kokoroVoices, id: \.id) { Text($0.name).tag(Speaker.kokoroPrefix + $0.id) }
                        }
                        Section("macOS voices") {
                        ForEach(voices, id: \.identifier) { Text(Speaker.label($0)).tag($0.identifier) }
                        }
                    }.frame(maxWidth: 320)
                    Spacer()
                    Text("Speed").foregroundStyle(.secondary)
                    Slider(value: $store.speed, in: 0.5...1.6).frame(width: 110)
                    Text(String(format: "%.1fx", store.speed)).monospacedDigit().frame(width: 36)
                }
                HStack {
                    Text("Meeting audio").foregroundStyle(.secondary)
                    Picker("Meeting audio", selection: $store.captureMode) {
                        Text("Mic").tag("mic"); Text("System").tag("system"); Text("Mic + System").tag("both")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    Button("Test system audio") { store.onTestSystemAudio() }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Records 4 seconds of whatever your Mac is playing and reports whether it was heard.")
                        .help("Mic = you and the room. System = Teams/Zoom/browser audio. Needs Screen & System Audio Recording permission.")
                    Spacer()
                }
                HStack {
                    Toggle("Auto-read after transcribing", isOn: $store.autoRead)
                    Toggle("Detect speakers", isOn: $store.detectSpeakers)
                        .help("Labels who is talking (Person 1, Person 2…). Slower; first use downloads ~100 MB.")
                    Spacer()
                    if speaker.currentID != nil {
                        Button { speaker.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    } else {
                        Button { speaker.speak(store.items.reversed()) } label: {
                            Label("Read all", systemImage: "play.fill")
                        }.disabled(store.items.isEmpty)
                    }
                }
                HStack(spacing: 8) {
                    if store.recording { Image(systemName: "record.circle.fill").foregroundStyle(.red) }
                    if store.spinning { ProgressView().controlSize(.small) }
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { showModels = true } label: { Label("Models…", systemImage: "externaldrive") }
                        .buttonStyle(.borderless).font(.caption)
                    Text("⌘D dictate · ⇧⌘D meeting · ⌥⌘D read").font(.caption).foregroundStyle(.tertiary)
                }
            }.padding(12)
        }
        .frame(minWidth: 520, minHeight: 440)
        .sheet(isPresented: $showModels) { ModelsView(models: models) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = Store()
    lazy var speaker = Speaker(store: store)
    let models = ModelManager()
    var recorder: AVAudioRecorder?
    var whisper: WhisperKit?
    var diarizer: OfflineDiarizerManager?
    var hotKeys: [EventHotKeyRef?] = []
    var window: NSWindow!
    var busy = false
    var meetingMode = false
    var recordingActive = false
    var starting = false
    var startTime = Date()
    var micStart = Date()
    var capture = CaptureMode.mic
    var sysRecorder: SystemAudioRecorder?
    var sysURL = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-system.wav")
    var timer: Timer?
    var activity: NSObjectProtocol?
    var fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("dictaphone.wav")

    func applicationDidFinishLaunching(_ n: Notification) {
        setIcon("mic", "Loading model…")
        store.onTestSystemAudio = { [weak self] in self?.testSystemAudio() }
        models.onNeuralRemoved = { [weak self] in self?.speaker.unloadNeural() }
        models.onSpeakerRemoved = { [weak self] in self?.diarizer = nil }
        buildWindow()
        buildMenu()
        registerHotKeys()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        showWindow()
        if CommandLine.arguments.contains("--test-system-audio") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.testSystemAudio() }
        }
        Task {
            do {
                whisper = try await WhisperKit(WhisperKitConfig(model: "base.en"))
                log("model loaded")
                await MainActor.run { self.setIcon("mic", "Ready — press ⌘D"); self.store.status = "Ready — press ⌘D to record" }
            } catch {
                log("model load failed: \(error)")
                await MainActor.run { self.store.status = "Model load failed: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: UI
    func setIcon(_ symbol: String, _ tip: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        statusItem.button?.toolTip = tip
    }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Start/Stop Recording (⌘D)", action: #selector(toggle), keyEquivalent: "")
        m.addItem(withTitle: "Start/Stop Meeting (⇧⌘D)", action: #selector(toggleMeeting), keyEquivalent: "")
        m.addItem(withTitle: "Read Latest Aloud (⌥⌘D)", action: #selector(readLatest), keyEquivalent: "")
        m.addItem(withTitle: "Show Transcripts / Models", action: #selector(showWindow), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        statusItem.menu = m
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Dictaphone"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: ContentView(store: store, speaker: speaker, models: models))
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Hotkeys (global, no accessibility permission needed)
    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ud in
            let me = Unmanaged<AppDelegate>.fromOpaque(ud!).takeUnretainedValue()
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            log("hotkey pressed id=\(hk.id)")
            DispatchQueue.main.async {
                switch hk.id { case 1: me.toggle(); case 3: me.toggleMeeting(); default: me.readLatest() }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        for (id, mods) in [(UInt32(1), UInt32(cmdKey)), (2, UInt32(cmdKey | optionKey)), (3, UInt32(cmdKey | shiftKey))] {
            var ref: EventHotKeyRef?
            let rc = RegisterEventHotKey(UInt32(kVK_ANSI_D), mods, EventHotKeyID(signature: OSType(0x44494354), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
            log("RegisterEventHotKey id=\(id) rc=\(rc)")
            hotKeys.append(ref)
        }
    }

    // MARK: Reading
    @objc func readLatest() {
        if speaker.currentID != nil { speaker.stop(); return }
        guard let t = store.items.first else { NSSound.beep(); return }
        speaker.speak([t])
    }

    // MARK: Recording
    @objc func toggle() {
        if recordingActive { stopAndTranscribe() } else { start(meeting: false) }
    }

    @objc func toggleMeeting() {
        if recordingActive { stopAndTranscribe() } else { start(meeting: true) }
    }

    func start(meeting: Bool) {
        guard !busy, !starting, whisper != nil else { log("start blocked busy=\(busy) model=\(whisper != nil)"); NSSound.beep(); return }
        speaker.stop()
        meetingMode = meeting
        let mode = meeting ? (CaptureMode(rawValue: store.captureMode) ?? .both) : .mic
        let tmp = FileManager.default.temporaryDirectory
        fileURL = tmp.appendingPathComponent(meeting ? "meeting.wav" : "dictaphone.wav")
        sysURL = tmp.appendingPathComponent("meeting-system.wav")
        starting = true
        Task {
            var usedMode = mode
            var warning: String?
            if mode != .mic {
                let rec = SystemAudioRecorder()
                do {
                    try await rec.start(to: sysURL)
                    sysRecorder = rec
                } catch {
                    log("system audio failed: \(error)")
                    usedMode = .mic
                    warning = "System audio unavailable — allow Dictaphone in Privacy & Security → Screen & System Audio Recording, then relaunch. Recording mic only."
                    if !CGPreflightScreenCaptureAccess() {
                        CGRequestScreenCaptureAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            let m = usedMode, w = warning
            await MainActor.run { self.beginRecording(meeting: meeting, mode: m, warning: w) }
        }
    }

    func beginRecording(meeting: Bool, mode: CaptureMode, warning: String?) {
        starting = false
        capture = mode
        do {
            if mode != .system {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                ]
                recorder = try AVAudioRecorder(url: fileURL, settings: settings)
                guard recorder!.record() else { throw NSError(domain: "Dictaphone", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable — check permissions"]) }
            }
            micStart = Date(); startTime = micStart
            recordingActive = true
            setIcon("record.circle.fill", "Recording…")
            statusItem.button?.contentTintColor = .systemRed
            store.recording = true
            let sources = mode == .both ? "mic + system audio" : (mode == .system ? "system audio" : "mic")
            let stopKey = meeting ? "⇧⌘D" : "⌘D"
            store.status = meeting ? "Recording meeting (\(sources))… 00:00 — press \(stopKey) to stop" : "Recording… press ⌘D to stop"
            if let warning { store.status = warning }
            NSSound(named: "Tink")?.play()
            if meeting {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording a meeting")
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self, warning == nil else { return }
                    self.store.status = "Recording meeting (\(sources))… \(clock(Date().timeIntervalSince(self.startTime))) — press \(stopKey) to stop"
                }
            }
        } catch {
            store.status = "Could not record: \(error.localizedDescription)"
            let rec = sysRecorder; sysRecorder = nil
            Task { await rec?.stop() }
        }
    }

    func stopAndTranscribe() {
        let duration = Date().timeIntervalSince(startTime)
        recordingActive = false
        recorder?.stop()
        recorder = nil
        let sysRec = sysRecorder
        sysRecorder = nil
        timer?.invalidate(); timer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        NSSound(named: "Pop")?.play()
        statusItem.button?.contentTintColor = nil
        setIcon("waveform", "Transcribing…")
        store.recording = false
        store.status = meetingMode ? "Transcribing meeting… this can take a few minutes" : "Transcribing…"
        store.spinning = true
        busy = true
        if meetingMode {
            let mode = capture
            Task {
                await sysRec?.stop()
                let offset = sysRec?.firstBufferAt.map { Float($0.timeIntervalSince(self.micStart)) } ?? 0
                await self.processMeeting(duration: duration, mode: mode, systemOffset: mode == .both ? offset : 0)
            }
            return
        }
        let detect = store.detectSpeakers
        Task {
            var text = ""
            var turns: [Turn]?
            do {
                let results = try await whisper!.transcribe(
                    audioPath: fileURL.path, decodeOptions: DecodingOptions(wordTimestamps: detect))
                text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if detect {
                    let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }.filter { !$0.word.hasPrefix("<|") }
                        .map { (word: $0.word, start: $0.start, end: $0.end) }
                    do { turns = try await self.diarize(words) } catch { log("diarization failed: \(error)") }
                }
            } catch {
                log("transcription failed: \(error)")
            }
            let result = text, resultTurns = turns
            await MainActor.run { self.finish(result, turns: resultTurns) }
        }
    }

    /// Runs the diarizer over the recording and assigns each transcribed word to a speaker.
    func diarize(_ words: [(word: String, start: Float, end: Float)], file: URL? = nil, keepSingle: Bool = false) async throws -> [Turn]? {
        guard !words.isEmpty else { return nil }
        if diarizer == nil {
            await MainActor.run { self.store.status = "Detecting speakers (first use downloads models)…" }
            let d = OfflineDiarizerManager()
            try await d.prepareModels()
            diarizer = d
        } else {
            await MainActor.run { self.store.status = "Detecting speakers…" }
        }
        let segs = try await diarizer!.process(file ?? fileURL).segments
        guard !segs.isEmpty else { return nil }
        var order: [String: Int] = [:]
        var turns: [Turn] = []
        for w in words {
            let mid = (w.start + w.end) / 2
            func gap(_ s: TimedSpeakerSegment) -> Float { max(s.startTimeSeconds - mid, mid - s.endTimeSeconds, 0) }
            guard let seg = segs.min(by: { gap($0) < gap($1) }) else { continue }
            if order[seg.speakerId] == nil { order[seg.speakerId] = order.count + 1 }
            let n = order[seg.speakerId]!
            if let last = turns.last, last.speaker == n { turns[turns.count - 1].text += w.word }
            else { turns.append(Turn(speaker: n, text: w.word, start: w.start)) }
        }
        guard order.count > 1 || keepSingle else { return nil }   // single speaker → plain transcript
        return turns.map { Turn(speaker: $0.speaker, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start) }
            .filter { !$0.text.isEmpty }
    }

    // MARK: System audio self-test
    func testSystemAudio() {
        guard !recordingActive, !starting, !busy else { return }
        store.status = "Testing system audio — play some sound for 4 seconds…"
        store.spinning = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-test.wav")
        Task {
            let rec = SystemAudioRecorder()
            var msg: String
            do {
                try await rec.start(to: url)
                try await Task.sleep(nanoseconds: 4_000_000_000)
                await rec.stop()
                let peak = Self.peak(of: url)
                if rec.firstBufferAt == nil { msg = "✗ System audio started but no audio arrived — play some sound and test again." }
                else if peak > 0.005 { msg = "✓ System audio works — it heard sound (level \(String(format: "%.2f", peak)))." }
                else { msg = "System audio is connected but heard silence — play something (music, a video) and test again." }
            } catch {
                msg = "✗ System audio blocked — allow Dictaphone in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch."
                if !CGPreflightScreenCaptureAccess() {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                log("system audio test error: \(error)")
            }
            try? FileManager.default.removeItem(at: url)
            log("system audio test: \(msg)")
            let m = msg
            await MainActor.run { self.store.status = m; self.store.spinning = false }
        }
    }

    static func peak(of url: URL) -> Float {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { return 0 }
        var p: Float = 0
        for i in 0..<Int(buf.frameLength) { p = max(p, abs(ch[i])) }
        return p
    }

    // MARK: Meeting mode
    typealias Words = [(word: String, start: Float, end: Float)]

    func transcribeTrack(_ url: URL) async throws -> (text: String, words: Words) {
        let results = try await whisper!.transcribe(
            audioPath: url.path, decodeOptions: DecodingOptions(wordTimestamps: true, chunkingStrategy: .vad))
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let words: Words = results.flatMap(\.segments).flatMap { $0.words ?? [] }.filter { !$0.word.hasPrefix("<|") }
            .map { (word: $0.word, start: $0.start, end: $0.end) }
        return (text, words)
    }

    /// Transcribes each recorded track, detects speakers within it, and merges everything by time.
    /// Mic + system: the mic's loudest voice is "You", other mic voices are "Room N", remote voices are "Remote N".
    func processMeeting(duration: Double, mode: CaptureMode, systemOffset: Float) async {
        var all: [Turn] = []
        var names: [String: String] = [:]
        var nextID = 1
        var fullText: [String] = []

        func addTrack(_ url: URL, isSystem: Bool, offset: Float) async {
            do {
                let (text, words) = try await transcribeTrack(url)
                guard !text.isEmpty else { return }
                await MainActor.run { self.store.status = "Working out who said what…" }
                var turns: [Turn] = []
                do { turns = try await diarize(words, file: url, keepSingle: true) ?? [] } catch { log("diarization failed: \(error)") }
                if turns.isEmpty { turns = [Turn(speaker: 1, text: text, start: words.first?.start ?? 0)] }
                // rank this track's speakers by how much they said
                let talk = Dictionary(grouping: turns, by: \.speaker).mapValues { $0.reduce(0) { $0 + $1.text.count } }
                var ids: [Int: Int] = [:]
                for (rank, sp) in talk.sorted(by: { $0.value > $1.value }).map(\.key).enumerated() {
                    ids[sp] = nextID
                    if isSystem { names[String(nextID)] = "Remote \(rank + 1)" }
                    else if mode == .both { names[String(nextID)] = rank == 0 ? "You" : "Room \(rank)" }
                    nextID += 1
                }
                for t in turns {
                    all.append(Turn(speaker: ids[t.speaker]!, text: t.text, start: max((t.start ?? 0) + offset, 0)))
                }
                fullText.append(text)
            } catch {
                log("meeting transcription failed: \(error)")
            }
        }

        if mode != .system { await addTrack(fileURL, isSystem: false, offset: 0) }
        if mode != .mic { await addTrack(sysURL, isSystem: true, offset: systemOffset) }

        all.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        var merged: [Turn] = []
        for t in all {
            if let l = merged.last, l.speaker == t.speaker { merged[merged.count - 1].text += " " + t.text } else { merged.append(t) }
        }
        let text = merged.map(\.text).joined(separator: " ")
        let result = merged, resultNames = names.isEmpty ? nil : names
        await MainActor.run { self.finishMeeting(text, turns: result, names: resultNames, duration: duration) }
    }

    func finishMeeting(_ text: String, turns: [Turn], names: [String: String]?, duration: Double) {
        busy = false
        meetingMode = false
        store.spinning = false
        setIcon("mic", "Ready — press ⌘D")
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: sysURL)
        guard !text.isEmpty else { store.status = "Nothing heard"; return }
        let title = "Meeting — " + Date().formatted(date: .abbreviated, time: .shortened)
        let t = store.add(text, turns: turns, meeting: MeetingInfo(title: title, duration: duration), names: names)
        showWindow()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.markdown, forType: .string)
        store.status = "Meeting saved — Markdown copied to clipboard"
    }

    func finish(_ text: String, turns: [Turn]?) {
        busy = false
        store.spinning = false
        setIcon("mic", "Ready — press ⌘D")
        guard !text.isEmpty else { store.status = "Nothing heard"; return }
        let t = store.add(text, turns: turns)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.displayText, forType: .string)
        store.status = "Copied to clipboard"
        showWindow()
        if store.autoRead { speaker.speak([t]) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
