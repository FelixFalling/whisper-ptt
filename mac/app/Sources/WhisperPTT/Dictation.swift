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
        case desktop(String)            // Whisper is on there and answers; the desktop's name
        case starting(String)           // Whisper is on there but does not answer yet
        case off(String)                // the desktop is up, Whisper is switched off there
        case away                       // nothing answers: asleep, shut down, or no Tailscale
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
    @Published private(set) var remoteSwitch = false    // the desktop's switch answers: Whisper there can be flipped from here
    @Published private(set) var switching: Bool?        // the position the desktop is being switched to
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
    private var timer: Timer?
    private var checks = 0                          // raised by a switch: a check begun before it is stale
    private var checkInFlight = false
    private var lastCheck = Date.distantPast
    private var startingSince = Date.distantPast
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
        schedule()
        // What was true before the lid closed need not be now. Tailscale takes a moment.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                self?.refreshLink()
            }
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
            prepareLocal()
            return nil
        }
        // Already known not to answer: load this Mac's model now, not after the timeout.
        // The desktop is still asked, in case it came back since the last check.
        switch link {
        case .off, .away, .starting: prepareLocal()
        default: break
        }
        let cleanup = cleanup, timeout = config.connectTimeout
        return Task {
            do {
                try await desktop.warm(cleanup: cleanup, timeout: timeout)
                return true
            } catch {
                Log.write("desktop not reachable: \(error.localizedDescription)")
                prepareLocal()
                switch link {
                case .desktop, .checking: refreshLink()     // switched off there, or gone?
                default: break
                }
                return false
            }
        }
    }

    private func prepareLocal() {
        if fallbackAvailable { local.prepare(config) }
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
            if fallbackAvailable {
                fail("Neither the desktop nor this Mac could transcribe that")
            } else if case .off = link {
                fail("Whisper is off on the desktop. Switch it on in this menu.")
            } else {
                fail("The desktop could not transcribe that. Is it awake?")
            }
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
        if timer != nil { schedule() }
    }

    /// Whisper at the desktop, as the menu's switch shows it.
    var desktopOn: Bool {
        if let switching { return switching }
        switch link {
        case .desktop, .starting: return true
        default: return false
        }
    }

    /// Switches Whisper on or off at the desktop, like the Whisper button in its own menu.
    func setDesktop(_ on: Bool) {
        guard !previewing, let desktop, switching == nil, on != desktopOn else { return }
        switching = on
        checks += 1                     // a check already on its way would show the old position
        Task {
            do {
                let now = try await desktop.setPower(on, timeout: 100)
                Log.write("switched Whisper \(on ? "on" : "off") at \(now.host)"
                          + (now.note.map { ": \($0)" } ?? ""))
                switching = nil
                remoteSwitch = true
                problem = nil
                setLink(on ? .starting(now.host) : .off(now.host))
            } catch {
                switching = nil
                fail("Could not switch Whisper \(on ? "on" : "off") on the desktop: \(error.localizedDescription)")
                refreshLink()
            }
        }
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

    /// Asks the desktop's two servers at once: the transcriber, which answers while Whisper
    /// is on there, and the remote switch, which answers whenever the desktop is up.
    func refreshLink() {
        guard let desktop, switching == nil, !checkInFlight else { return }
        checkInFlight = true
        let check = checks
        lastCheck = Date()
        Task {
            async let transcriber = Self.outcome { try await desktop.health(timeout: 3) }
            async let power = Self.outcome { try await desktop.state(timeout: 3) }
            let (health, state) = await (transcriber, power)
            checkInFlight = false
            guard check == checks else {
                refreshLink()                           // the desktop was switched meanwhile: ask again
                return
            }
            remoteSwitch = (try? state.get()) != nil
            switch (health, state) {
            case (.success(let name), _):
                setLink(.desktop(name))
            case (.failure, .success(let state)):
                setLink(state.active ? .starting(state.host) : .off(state.host))
            case (.failure(let error), .failure):
                setLink(.away, why: error.localizedDescription)
            }
        }
    }

    private static func outcome<T>(_ work: () async throws -> T) async -> Swift.Result<T, Error> {
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }

    private func setLink(_ now: Link, why: String? = nil) {
        guard now != link else { return }
        switch now {
        case .desktop(let name): Log.write("connected to \(name)")
        case .starting(let name): Log.write("Whisper is starting on \(name)")
        case .off(let name): Log.write("\(name) is up, Whisper is off there")
        case .away: Log.write("desktop away" + (why.map { ": \($0)" } ?? ""))
        case .checking, .notSetUp: break
        }
        if case .starting = now { startingSince = Date() }
        link = now
        if timer != nil { schedule() }
    }

    private func checkTerminalClient() {
        Task.detached {
            let running = TerminalClient.isRunning()
            await MainActor.run { self.terminalClientRunning = running }
        }
    }

    /// Every two seconds while something is about to change (a permission being granted,
    /// Whisper starting at the desktop), otherwise once a minute. It used to wake the Mac
    /// every two seconds for as long as the app ran.
    private func tick() {
        if enabled, !watcher.isRunning { watcher.start() }   // succeeds once macOS allows it
        refreshPermissions()
        if isStarting || Date().timeIntervalSince(lastCheck) >= 55 { refreshLink() }
        if config.fallbackKeepLoaded > 0, busy == 0, !capturing {
            local.retire(idleFor: config.fallbackKeepLoaded)
        }
        schedule()
    }

    private var isStarting: Bool {
        if case .starting = link { return Date().timeIntervalSince(startingSince) < 60 }
        return false
    }

    private func schedule() {
        let soon = !missing.isEmpty || (enabled && !watcher.isRunning) || isStarting
        timer?.invalidate()
        let next = Timer(timeInterval: soon ? 2 : 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = soon ? 0.3 : 6
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    // MARK: Permissions

    func refreshPermissions() {
        var now: [Permission] = []
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { now.append(.microphone) }
        if !AXIsProcessTrusted() { now.append(.accessibility) }
        if !watcher.isRunning, !CGPreflightListenEventAccess() { now.append(.inputMonitoring) }
        if now != missing {
            missing = now
            if timer != nil { schedule() }
        }
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
                 recording: Bool = false, remoteSwitch: Bool = true) {
        previewing = true
        self.remoteSwitch = remoteSwitch
        self.link = link
        self.last = last
        self.missing = missing
        self.problem = problem
        self.recording = recording
    }
}
