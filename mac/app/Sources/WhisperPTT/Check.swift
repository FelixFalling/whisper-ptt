import SwiftUI

/// `WhisperPTT --check [speech.wav]` tries the settings, the desktop and the fallback from a
/// terminal, without the menu bar. Given a 16 kHz mono 16-bit WAV, it also transcribes it on
/// the desktop with cleanup off and on, and on this Mac. The exit status is 0 when
/// everything answered.
///
/// `WhisperPTT --desktop on|off|status` flips or reads the desktop's Whisper switch, as the
/// menu does.
enum Check {
    private final class Outcome: @unchecked Sendable {
        var ok = false
    }

    static func run(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)     // each line as it happens, also through SSH
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        if args.contains("--desktop") {
            let wanted = args.drop { $0 != "--desktop" }.dropFirst().first ?? "status"
            guard ["on", "off", "status"].contains(wanted) else {
                print("usage: WhisperPTT --desktop on|off|status")
                return 2
            }
            Task.detached {
                outcome.ok = await desktopSwitch(wanted)
                done.signal()
            }
        } else {
            let path = args.drop { $0 != "--check" }.dropFirst().first
            let wav = path.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            if path != nil, wav == nil { print("cannot read \(path!)") }
            Task.detached {
                outcome.ok = await checks(wav)
                done.signal()
            }
        }
        done.wait()
        return outcome.ok ? 0 : 1
    }

    private static func desktopSwitch(_ wanted: String) async -> Bool {
        let (cfg, problem) = Config.load()
        guard problem == nil, let desktop = Desktop(cfg) else {
            print(problem ?? "The desktop is not set up in mac.json")
            return false
        }
        do {
            let now = wanted == "status"
                ? try await desktop.state(timeout: 5)
                : try await desktop.setPower(wanted == "on", timeout: 100)
            print("\(now.host): Whisper is \(now.active ? "on" : "off")" + (now.note.map { " (\($0))" } ?? ""))
            guard wanted == "on" else { return true }
            for _ in 0..<40 {                       // its transcriber needs a few seconds
                if (try? await desktop.health(timeout: 2)) != nil {
                    print("\(now.host): ready to transcribe")
                    return true
                }
                try? await Task.sleep(for: .seconds(1))
            }
            print("\(now.host): switched on, but its transcriber does not answer at \(cfg.server)")
            return false
        } catch {
            print("the desktop's switch at \(desktop.control.absoluteString): \(error.localizedDescription)")
            return false
        }
    }

    private static func checks(_ wav: Data?) async -> Bool {
        var ok = true
        let (cfg, problem) = Config.load()
        print("settings  \(Config.url.path): \(problem ?? "ok")")
        if TriggerKey.named(cfg.key) == nil {
            print("key       unknown \"\(cfg.key)\"")
            ok = false
        }
        if problem == nil, let desktop = Desktop(cfg) {
            // Not counted against the exit status: an older desktop has no remote switch.
            do {
                let power = try await desktop.state(timeout: 5)
                print("switch    \(power.host): Whisper is \(power.active ? "on" : "off") there")
            } catch {
                print("switch    no answer at \(desktop.control.absoluteString): \(error.localizedDescription)")
            }
            do {
                print("desktop   \(try await desktop.health(timeout: 5)) answers at \(cfg.server)")
                if let wav {
                    for cleanup in [false, true] {
                        let text = try await desktop.transcribe(wav, cleanup: cleanup, timeout: cfg.transcribeTimeout)
                        print("          cleanup \(cleanup ? "on: " : "off:") \(text)")
                    }
                }
            } catch {
                print("desktop   \(error.localizedDescription)")
                ok = false
            }
        } else {
            ok = false
        }
        let local = LocalTranscriber(python: cfg.fallbackPythonPath)
        if !cfg.fallback {
            print("fallback  off in mac.json")
        } else if !local.isAvailable {
            print("fallback  not installed: no \(cfg.fallbackPythonPath)")
            ok = false
        } else {
            do {
                try await local.ping()
                print("fallback  mlx-whisper is ready (\(cfg.fallbackModel))")
                if let wav {
                    var begun = Date()
                    try await local.load(cfg)       // what a key press starts while you speak
                    print(String(format: "          model loaded in %.2fs", Date().timeIntervalSince(begun)))
                    begun = Date()
                    let text = try await local.transcribe(wav, cfg: cfg)
                    print(String(format: "          on this Mac, %.2fs: %@", Date().timeIntervalSince(begun), text))
                }
            } catch {
                print("fallback  \(error.localizedDescription)")
                ok = false
            }
            local.shutdown()
        }
        return ok
    }
}

/// `WhisperPTT --snapshot <folder>` draws the menu and the setup window, light and dark, to
/// PNG files, for checking the design without clicking through the app.
@MainActor
enum Snapshot {
    static func render(into folder: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let d = Dictation()
        let sample = Dictation.Result(
            text: "Can we move the design review to Thursday afternoon? I'd like one more day with the prototype before we show it.",
            speech: 7.4, took: 1.3, place: "desktop")
        d.preview(link: .desktop("desktop"), last: sample)
        save(Panel().environmentObject(d), dark: false, as: dir.appendingPathComponent("menu-light.png"))
        save(Panel().environmentObject(d), dark: true, as: dir.appendingPathComponent("menu-dark.png"))
        d.preview(link: .off("desktop"), last: sample)
        save(Panel().environmentObject(d), dark: false, as: dir.appendingPathComponent("menu-desktop-off.png"))
        d.preview(link: .starting("desktop"), last: nil)
        save(Panel().environmentObject(d), dark: true, as: dir.appendingPathComponent("menu-desktop-starting.png"))
        d.preview(link: .desktop("desktop"), last: nil, remoteSwitch: false)
        save(Panel().environmentObject(d), dark: false, as: dir.appendingPathComponent("menu-no-switch.png"))
        d.preview(link: .away, last: nil, missing: [.accessibility],
                  problem: "Neither the desktop nor this Mac could transcribe that", recording: true)
        save(Panel().environmentObject(d), dark: false, as: dir.appendingPathComponent("menu-trouble.png"))
        d.preview(link: .checking, last: nil, missing: [.accessibility, .inputMonitoring])
        save(SetupView().environmentObject(d), dark: false, as: dir.appendingPathComponent("setup-light.png"))
        save(SetupView().environmentObject(d), dark: true, as: dir.appendingPathComponent("setup-dark.png"))
    }

    private static func save<V: View>(_ view: V, dark: Bool, as url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: host.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }
}
