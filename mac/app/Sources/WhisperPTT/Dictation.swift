import AppKit
import AVFoundation

/// Hold the key, speak, let go: the recording goes to the desktop (or, when it is away, to
/// this Mac's slower fallback) and the text is pasted at the cursor. Also everything the
/// menu shows and switches.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Link: Equatable {
        case checking
        case desktop(String)            // connected, with the desktop's name
        case away
        case notSetUp(String)           // what is missing from mac.json
    }

    struct Result {
        let text: String
        let speech: Double              // seconds of audio
        let took: Double                // seconds from release to text
        let place: String               // where it was transcribed
    }

    // The two switches, remembered across launches.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "enabled")
            applyEnabled()
        }
    }
    @Published var cleanup: Bool {
        didSet { UserDefaults.standard.set(cleanup, forKey: "cleanup") }
    }

    @Published private(set) var recording = false   // a press that outlasted min_duration
    @Published private(set) var busy = 0            // dictations being transcribed or pasted
    @Published private(set) var link = Link.checking
    @Published private(set) var last: Result?
    @Published private(set) var problem: String?    // the last thing that went wrong
    @Published private(set) var missing: [Permission] = []
    @Published private(set) var terminalClientRunning = false
    @Published private(set) var copied = false      // the last dictation was just copied again

    let config: Config
    let configProblem: String?
    let key: TriggerKey
    let local: LocalTranscriber
    private let desktop: Desktop?
    private let watcher: KeyWatcher
    private let recorder = Recorder()

    private var capturing = false
    private var cancelled = false
    private var started = Date()
    private var press = 0
    private var warm: Task<Bool, Never>?
    private var queue: Task<Void, Never>?           // the newest dictation; each awaits the one before
    private var asked: Set<Permission> = []
    private var ticks = 0
    private var timer: Timer?
    private var previewing = false                  // drawn by --snapshot, not live

    init() {
        let (cfg, problem) = Config.load()
        let key = TriggerKey.named(cfg.key) ?? TriggerKey.named("alt_r")!
        config = cfg
        configProblem = problem ?? (TriggerKey.named(cfg.key) == nil ? "Unknown key \"\(cfg.key)\" in mac.json" : nil)
        self.key = key
        desktop = problem == nil ? Desktop(cfg) : nil
        local = LocalTranscriber(python: cfg.fallbackPythonPath)
        watcher = KeyWatcher(key: key)
        UserDefaults.standard.register(defaults: ["enabled": true, "cleanup": true])
        enabled = UserDefaults.standard.bool(forKey: "enabled")
        cleanup = UserDefaults.standard.bool(forKey: "cleanup")
        if let configProblem { link = .notSetUp(configProblem) }
        watcher.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.keyEvent(event) }
        }
    }

    var fallbackAvailable: Bool { config.fallback && local.isAvailable }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func launch() {
        Log.write("Whisper PTT \(version) started; settings \(Config.url.path)"
                  + (configProblem.map { ": \($0)" } ?? ""))
        applyEnabled()
        refreshPermissions()
        refreshLink()
        checkTerminalClient()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if !missing.isEmpty || configProblem != nil { SetupWindow.show(self) }
    }

    func shutdown() {
        local.shutdown()
    }

    /// Whenever the menu opens.
    func menuOpened() {
        guard !previewing else { return }
        refreshPermissions()
        refreshLink()
        checkTerminalClient()
    }

    // MARK: Hold, speak, release

    private func keyEvent(_ event: KeyWatcher.Event) {
        switch event {
        case .down: begin()
        case .up: end()
        case .otherKey:
            if capturing {
                cancelled = true            // the key is being used as a modifier
                recording = false
            }
        }
    }

    private func begin() {
        guard enabled, !capturing else { return }
        capturing = true
        cancelled = false
        started = Date()
        press += 1
        let thisPress = press
        warm = startWarming()
        do {
            try recorder.start()
        } catch {
            capturing = false
            fail("Could not open the microphone: \(error.localizedDescription)")
            return
        }
        // Tick only once a press outlasts min_duration, so Option used for an accent stays silent.
        Task {
            try? await Task.sleep(for: .seconds(config.minDuration))
            guard capturing, !cancelled, press == thisPress else { return }
            recording = true
            Sound.play("Tink", if: config.sounds)
        }
    }

    /// Asks the desktop to load its models while the key is still held. The answer also
    /// tells whether the desktop is reachable at all.
    private func startWarming() -> Task<Bool, Never>? {
        guard let desktop else {
            if fallbackAvailable { local.prepare() }
            return nil
        }
        let cleanup = cleanup, timeout = config.connectTimeout
        return Task {
            do {
                try await desktop.warm(cleanup: cleanup, timeout: timeout)
                return true
            } catch {
                Log.write("desktop not reachable: \(error.localizedDescription)")
                link = .away
                if fallbackAvailable { local.prepare() }
                return false
            }
        }
    }

    private func end() {
        guard capturing else { return }
        capturing = false
        recording = false
        let audio = recorder.stop()
        let held = Date().timeIntervalSince(started)
        guard !cancelled, held >= config.minDuration, !audio.isEmpty else { return }
        let warm = warm
        busy += 1
        let previous = queue
        queue = Task {
            await previous?.value
            await finish(audio, warm: warm)
            busy -= 1
        }
    }

    private func finish(_ audio: [Float], warm: Task<Bool, Never>?) async {
        let wav = Audio.wav(audio)
        let speech = Double(audio.count) / Audio.rate
        let begun = Date()
        var text: String?
        var place = ""

        let reachable = await warm?.value ?? false
        if let desktop, reachable {
            do {
                text = try await desktop.transcribe(wav, cleanup: cleanup, timeout: config.transcribeTimeout)
                if case .desktop(let name) = link {
                    place = name
                } else {
                    place = "the desktop"
                    refreshLink()                   // it was away until this press
                }
            } catch {
                Log.write("desktop failed: \(error.localizedDescription)")
            }
        }
        if text == nil, fallbackAvailable {
            do {
                text = try await local.transcribe(wav, cfg: config)
                place = "this Mac"
            } catch {
                Log.write("fallback on this Mac failed: \(error.localizedDescription)")
            }
        }
        let took = Date().timeIntervalSince(begun)
        guard var text else {
            fail(fallbackAvailable
                 ? "Neither the desktop nor this Mac could transcribe that"
                 : "The desktop could not transcribe that. Is Whisper on there?")
            return
        }
        Log.write(String(format: "%.1fs of speech -> %.2fs on %@, %d characters", speech, took, place, text.count))
        guard !text.isEmpty else { return }         // nothing was said
        last = Result(text: text, speech: speech, took: took, place: place)
        problem = nil
        if config.trailingSpace { text += " " }
        // Never paste while the key is held: Cmd+V with Option down is another command.
        while watcher.isDown { try? await Task.sleep(for: .milliseconds(30)) }
        if Paster.paste(text, restoreClipboard: config.restoreClipboard) {
            Sound.play("Pop", if: config.sounds)
        } else {
            problem = "Copied to the clipboard. Allow Accessibility to paste it for you."
            Sound.play("Basso", if: config.sounds)
            refreshPermissions()
        }
    }

    private func fail(_ message: String) {
        Log.write(message)
        problem = message
        Sound.play("Basso", if: config.sounds)
    }

    // MARK: Switches and status

    private func applyEnabled() {
        if enabled {
            watcher.start()
        } else {
            watcher.stop()
            if capturing {
                capturing = false
                recording = false
                _ = recorder.stop()
            }
        }
        refreshPermissions()
    }

    func copyLast() {
        guard let last else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    func dismissProblem() {
        problem = nil
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
        } catch {
            problem = "Could not change Open at Login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func quitTerminalClient() {
        TerminalClient.quit()
        checkTerminalClient()
    }

    func refreshLink() {
        guard let desktop else { return }
        Task {
            let now: Link
            do {
                now = .desktop(try await desktop.health(timeout: 3))
            } catch {
                now = .away
                if link != .away { Log.write("desktop away: \(error.localizedDescription)") }
            }
            if case .desktop(let name) = now, now != link { Log.write("connected to \(name)") }
            link = now
        }
    }

    private func checkTerminalClient() {
        Task.detached {
            let running = TerminalClient.isRunning()
            await MainActor.run { self.terminalClientRunning = running }
        }
    }

    private func tick() {
        if enabled, !watcher.isRunning { watcher.start() }   // succeeds once macOS allows it
        refreshPermissions()
        ticks += 1
        if ticks % 30 == 0 { refreshLink() }               // once a minute
    }

    // MARK: Permissions

    func refreshPermissions() {
        var now: [Permission] = []
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { now.append(.microphone) }
        if !AXIsProcessTrusted() { now.append(.accessibility) }
        if !watcher.isRunning, !CGPreflightListenEventAccess() { now.append(.inputMonitoring) }
        if now != missing { missing = now }
    }

    /// The first time, macOS's own prompt; after that, the page in System Settings.
    func request(_ permission: Permission) {
        let firstTime = asked.insert(permission).inserted
        switch permission {
        case .microphone where AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in Dictation.shared.refreshPermissions() }
            }
        case .accessibility where firstTime:
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring where firstTime:
            CGRequestListenEventAccess()
        default:
            NSWorkspace.shared.open(permission.settings)
        }
    }

    // MARK: For the menu bar and the screenshots in --snapshot

    var symbol: String {
        if !enabled { return "waveform.slash" }
        if recording { return "mic.fill" }
        if busy > 0 { return "text.bubble" }
        if !missing.isEmpty { return "waveform.badge.exclamationmark" }
        return "waveform"
    }

    func preview(link: Link, last: Result?, missing: [Permission] = [], problem: String? = nil,
                 recording: Bool = false) {
        previewing = true
        self.link = link
        self.last = last
        self.missing = missing
        self.problem = problem
        self.recording = recording
    }
}
