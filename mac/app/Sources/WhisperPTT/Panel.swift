import SwiftUI

// No @State in this app: in the macOS 27 SDK it is a macro whose plugin comes only with
// Xcode, and the app builds with the Command Line Tools. View state lives in
// ObservableObjects instead.

/// What opens from the menu bar icon, laid out like macOS's own menu bar modules (Wi-Fi,
/// Bluetooth): the main switch in the header, then rows with round icons.
struct Panel: View {
    @EnvironmentObject private var d: Dictation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Separator()
            notices
            connection
            ToggleRow(icon: "sparkles", title: "Cleanup", detail: cleanupDetail, isOn: $d.cleanup)
                .disabled(!d.enabled)
            if let last = d.last {
                Separator()
                lastDictation(last)
            }
            Separator()
            HoverBox {
                HStack {
                    Text("Open at Login").font(.system(size: 13))
                    Spacer()
                    Toggle("Open at Login", isOn: Binding(get: { LoginItem.isEnabled },
                                                          set: { d.setOpenAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            MenuItem("Settings File…") {
                NSWorkspace.shared.open([Config.url],
                                        withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            MenuItem("Show Log") { NSWorkspace.shared.open(Log.url) }
            Separator()
            MenuItem("Quit Whisper PTT", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(6)
        .frame(width: 320)
        .onAppear { d.menuOpened() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper on this Mac").font(.system(size: 13, weight: .semibold))
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Whisper", isOn: $d.enabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Cleanup is the desktop's work; this Mac's own transcriber types the words as spoken.
    private var cleanupDetail: String {
        if !d.cleanup { return "Types your words as spoken" }
        switch d.link {
        case .off, .starting, .away: return "Resumes when the desktop transcribes"
        default: return "Fixes grammar and filler words"
        }
    }

    private var status: String {
        if !d.enabled { return "Off" }
        if d.recording { return "Listening…" }
        if d.busy > 0 { return "Transcribing…" }
        if !d.missing.isEmpty { return "Needs your permission" }
        return "Hold \(d.key.label) to talk"
    }

    @ViewBuilder
    private var notices: some View {
        if d.enabled {
            ForEach(d.missing) { permission in
                Row(icon: permission.symbol, tint: .orange, title: "Allow \(permission.title)",
                    detail: permission.reason) { d.request(permission) }
            }
        }
        if d.terminalClientRunning {
            Row(icon: "terminal", tint: .orange, title: "The Terminal version is running",
                detail: "Click to quit it, so text is pasted once") { d.quitTerminalClient() }
        }
        if let problem = d.problem {
            Row(icon: "exclamationmark.triangle.fill", tint: .orange, title: problem,
                detail: "Click to dismiss") { d.dismissProblem() }
        }
    }

    @ViewBuilder
    private var connection: some View {
        switch d.link {
        case .checking:
            Row(icon: "desktopcomputer", tint: nil, title: "Looking for the desktop…",
                detail: "Over Tailscale")
        case .desktop(let name) where !d.remoteSwitch:
            // A desktop without the remote switch (an older whisper-ptt there).
            Row(icon: "desktopcomputer", tint: .accentColor, title: name,
                detail: "Connected, transcribes on its graphics card") { d.refreshLink() }
        case .desktop(let name):
            desktopSwitch(name, "On, transcribes on its graphics card")
        case .starting(let name):
            desktopSwitch(name, "Starting…")
        case .off(let name):
            desktopSwitch(name, d.fallbackAvailable ? "Off. This Mac transcribes instead"
                                                    : "Off. Switch it on to dictate")
        case .away:
            Row(icon: d.fallbackAvailable ? "laptopcomputer" : "desktopcomputer",
                tint: d.fallbackAvailable ? .orange : nil, title: "Desktop not reachable",
                detail: d.fallbackAvailable ? "This Mac transcribes instead"
                                            : "Asleep, shut down, or not on Tailscale") { d.refreshLink() }
        case .notSetUp(let why):
            Row(icon: "desktopcomputer", tint: nil, title: "Desktop not set up", detail: why) {
                NSWorkspace.shared.open(Config.url)
            }
        }
    }

    /// The desktop's own Whisper switch, flipped from here over Tailscale.
    private func desktopSwitch(_ name: String, _ detail: String) -> some View {
        ToggleRow(icon: "desktopcomputer", title: "Whisper on \(name)",
                  detail: d.switching.map { $0 ? "Switching on…" : "Switching off…" } ?? detail,
                  isOn: Binding(get: { d.desktopOn }, set: { d.setDesktop($0) }))
            .disabled(d.switching != nil)
    }

    private func lastDictation(_ last: Dictation.Result) -> some View {
        Button {
            d.copyLast()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Last dictation").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Label(d.copied ? "Copied" : "Copy", systemImage: d.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(d.copied ? Color.green : Color.secondary)
                }
                Text(last.text)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(String(format: "%.0f s of speech, ready %.1f s later on %@", last.speech, last.took, last.place))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(RowStyle())
    }
}

/// A round icon like Control Center's: filled with the tint when active, grey otherwise.
struct RoundIcon: View {
    let symbol: String
    let tint: Color?
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(tint ?? Color.primary.opacity(0.1)))
    }
}

/// A row with an icon, a title and a detail line; clickable when it has an action.
struct Row: View {
    let icon: String
    let tint: Color?
    let title: String
    let detail: String
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content }.buttonStyle(RowStyle())
        } else {
            HoverBox(highlights: false) { content }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            RoundIcon(symbol: icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).lineLimit(2)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }
}

/// A row with a switch. Clicking anywhere on it flips the switch, as in Control Center.
struct ToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(icon: String, title: String, detail: String, isOn: Binding<Bool>) {
        self.icon = icon
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        HoverBox {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    RoundIcon(symbol: icon, tint: isOn && isEnabled ? .accentColor : nil)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 13)).lineLimit(1)
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { isOn.toggle() } }
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        }
    }
}

/// A plain menu line, highlighted under the pointer like a menu item.
struct MenuItem: View {
    let title: String
    var shortcut: String?
    let action: () -> Void

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(RowStyle())
    }
}

struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBox(pressed: configuration.isPressed) { configuration.label }
    }
}

final class Hover: ObservableObject {
    @Published var on = false
}

/// The rounded highlight behind a row under the pointer.
struct HoverBox<Content: View>: View {
    let highlights: Bool
    let pressed: Bool
    let content: Content
    @StateObject private var hover = Hover()

    init(highlights: Bool = true, pressed: Bool = false, @ViewBuilder content: () -> Content) {
        self.highlights = highlights
        self.pressed = pressed
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? 0.14 : hover.on && highlights ? 0.08 : 0)))
            .contentShape(Rectangle())
            .onHover { hover.on = $0 }
    }
}

struct Separator: View {
    var body: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 5)
    }
}
