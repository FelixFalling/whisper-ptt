import SwiftUI

/// `WhisperPTT --check [speech.wav]` tries the settings, the desktop and the fallback from a
/// terminal, without the menu bar. Given a 16 kHz mono 16-bit WAV, it also transcribes it on
/// the desktop with cleanup off and on. The exit status is 0 when everything answered.
enum Check {
    private final class Outcome: @unchecked Sendable {
        var ok = false
    }

    static func run(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)     // each line as it happens, also through SSH
        let path = args.drop { $0 != "--check" }.dropFirst().first
        let wav = path.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            outcome.ok = await checks(wav)
            done.signal()
        }
        done.wait()
        return outcome.ok ? 0 : 1
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
