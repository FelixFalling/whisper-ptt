import AppKit
import AVFoundation
import ServiceManagement

/// ~/Library/Logs/Whisper PTT.log, also shown by "Show Log" in the menu. It records what
/// happened and how long it took, never the dictated text.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Whisper PTT.log")

    /// Opened for appending, so the fallback helper can write its errors here too.
    static let handle: FileHandle? = {
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        return fd < 0 ? nil : FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }()

    private static let stamp: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        try? handle?.write(contentsOf: Data(line.utf8))
    }
}

enum Sound {
    static func play(_ name: String, if enabled: Bool) {
        guard enabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// Pastes through the clipboard with Cmd+V, then puts back what was on it.
enum Paster {
    /// False when macOS does not allow posting keystrokes: the text is then left on the
    /// clipboard for pasting by hand.
    @MainActor
    static func paste(_ text: String, restoreClipboard: Bool) -> Bool {
        let board = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(board) : nil
        board.clearContents()
        board.setString(text, forType: .string)
        guard AXIsProcessTrusted() else { return false }
        let placed = board.changeCount

        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = KeyWatcher.ownEvents
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)   // V
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        if let saved {
            // Long enough for the app to read it; skipped if something new was copied since.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard board.changeCount == placed else { return }
                board.clearContents()
                board.writeObjects(saved)
            }
        }
        return true
    }

    /// Copies of everything on the clipboard, in every format (text, images, files).
    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}

/// What macOS has to allow before dictation works, in the order the setup window asks.
enum Permission: String, CaseIterable, Identifiable {
    case microphone, accessibility, inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var reason: String {
        switch self {
        case .microphone: "Hears you while you hold the key"
        case .accessibility: "Pastes the text where you are typing"
        case .inputMonitoring: "Notices the key in every app"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        }
    }

    /// Its page in System Settings, Privacy & Security.
    var settings: URL {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// The older Terminal client (mac/whisper-ptt-mac.py). Running both pastes everything twice.
enum TerminalClient {
    static func isRunning() -> Bool {
        run("/usr/bin/pgrep", "-f", "whisper-ptt-mac.py") == 0
    }

    static func quit() {
        _ = run("/usr/bin/pkill", "-f", "whisper-ptt-mac.py")
    }

    private static func run(_ tool: String, _ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
