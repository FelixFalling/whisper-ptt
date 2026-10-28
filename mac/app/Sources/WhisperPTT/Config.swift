import Foundation

/// Settings in ~/.config/whisper-ptt/mac.json, the same file the Terminal client
/// (mac/whisper-ptt-mac.py) reads. The menu's switches live in UserDefaults instead, so
/// flipping them never rewrites this file.
struct Config {
    var server = ""
    var token = ""
    var key = "alt_r"
    var minDuration = 0.35          // shorter presses are ignored
    var language = "en"
    var initialPrompt = ""
    var trailingSpace = true
    var fallback = true             // transcribe on this Mac when the desktop is away
    var fallbackModel = "mlx-community/whisper-large-v3-turbo"
    var fallbackPython = "~/.local/share/whisper-ptt-mac/venv/bin/python"   // mac/install.sh makes it
    var connectTimeout = 1.5        // how long to wait for the desktop before falling back
    // The Terminal client waits 30 s. A long dictation with cleanup can take longer on the
    // desktop, and giving up early would type it from this Mac without cleanup.
    var transcribeTimeout = 120.0
    var sounds = true
    var restoreClipboard = true     // put back what was on the clipboard after pasting

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/whisper-ptt/mac.json")

    /// The settings, and why the desktop cannot be used with them (nil when it can).
    static func load() -> (Config, problem: String?) {
        var cfg = Config()
        guard let data = try? Data(contentsOf: url) else {
            return (cfg, "No settings file at ~/.config/whisper-ptt/mac.json")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (cfg, "mac.json is not valid JSON")
        }
        func read<T>(_ key: String, _ value: inout T) {
            if let found = json[key] as? T { value = found }
        }
        read("server", &cfg.server)
        read("token", &cfg.token)
        read("key", &cfg.key)
        read("min_duration", &cfg.minDuration)
        read("language", &cfg.language)
        read("initial_prompt", &cfg.initialPrompt)
        read("trailing_space", &cfg.trailingSpace)
        read("fallback", &cfg.fallback)
        read("fallback_model", &cfg.fallbackModel)
        read("fallback_python", &cfg.fallbackPython)
        read("connect_timeout", &cfg.connectTimeout)
        read("transcribe_timeout", &cfg.transcribeTimeout)
        read("sounds", &cfg.sounds)
        read("restore_clipboard", &cfg.restoreClipboard)

        if cfg.server.isEmpty || cfg.server.contains("YOUR-DESKTOP") || URL(string: cfg.server)?.host == nil {
            return (cfg, "Add the desktop's address as \"server\" in mac.json")
        }
        if cfg.token.isEmpty || cfg.token.hasPrefix("REPLACE_") {
            return (cfg, "Add the desktop's server_token as \"token\" in mac.json")
        }
        return (cfg, nil)
    }

    var fallbackPythonPath: String { (fallbackPython as NSString).expandingTildeInPath }
}

/// The modifier key held to dictate, by its name in mac.json (pynput's names, which the
/// Terminal client used). `flag` is the key's own bit in CGEventFlags, which tells the left
/// and right keys apart.
struct TriggerKey {
    let keyCode: Int64
    let flag: UInt64
    let label: String

    static func named(_ name: String) -> TriggerKey? {
        switch name {
        case "alt_r": return TriggerKey(keyCode: 61, flag: 0x40, label: "right ⌥ Option")
        case "alt", "alt_l": return TriggerKey(keyCode: 58, flag: 0x20, label: "left ⌥ Option")
        case "cmd_r": return TriggerKey(keyCode: 54, flag: 0x10, label: "right ⌘ Command")
        case "cmd", "cmd_l": return TriggerKey(keyCode: 55, flag: 0x08, label: "left ⌘ Command")
        case "ctrl_r": return TriggerKey(keyCode: 62, flag: 0x2000, label: "right ⌃ Control")
        case "ctrl", "ctrl_l": return TriggerKey(keyCode: 59, flag: 0x01, label: "left ⌃ Control")
        case "shift_r": return TriggerKey(keyCode: 60, flag: 0x04, label: "right ⇧ Shift")
        case "shift", "shift_l": return TriggerKey(keyCode: 56, flag: 0x02, label: "left ⇧ Shift")
        default: return nil
        }
    }
}
