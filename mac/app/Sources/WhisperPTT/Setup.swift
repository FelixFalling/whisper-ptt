import SwiftUI

/// The window shown at launch while something is missing: what the app does, and the
/// three things macOS has to allow, each ticking green as it is granted.
struct SetupView: View {
    @EnvironmentObject private var d: Dictation

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Welcome to Whisper PTT")
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 10)
            Text("Hold \(d.key.label), speak, and let go. Your desktop's graphics card turns it into text, and it appears wherever you are typing.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(Array(Permission.allCases.enumerated()), id: \.element) { index, permission in
                    if index > 0 { Divider().padding(.leading, 56) }
                    PermissionRow(permission: permission, granted: !d.missing.contains(permission)) {
                        d.request(permission)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
            .padding(.top, 22)

            if let problem = d.configProblem {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(problem). Until then, dictation runs on this Mac.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open File") { NSWorkspace.shared.open(Config.url) }
                }
                .padding(.top, 16)
            }

            if !d.missing.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Text("Switched on in System Settings but not ticked here? That switch belongs to an earlier build of the app. Reset forgets those entries and opens Whisper PTT again, so macOS asks afresh.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Reset") { Permissions.resetAndRelaunch() }
                }
                .padding(.top, 16)
            }

            HStack {
                Label("Find it in the menu bar", systemImage: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(d.missing.isEmpty ? "Done" : "Later") { SetupWindow.close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 480)
    }
}

struct PermissionRow: View {
    let permission: Permission
    let granted: Bool
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundIcon(symbol: permission.symbol, tint: granted ? .green : .accentColor, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.system(size: 13, weight: .medium))
                Text(permission.reason).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: allow)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// Forgets what macOS remembers about this app's permissions, then opens it again.
enum Permissions {
    static func resetAndRelaunch() {
        let id = Bundle.main.bundleIdentifier ?? "com.felixfalling.whisper-ptt"
        for service in ["Accessibility", "ListenEvent", "PostEvent", "Microphone"] {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", service, id]
            reset.standardOutput = FileHandle.nullDevice
            reset.standardError = FileHandle.nullDevice
            try? reset.run()
            reset.waitUntilExit()
            Log.write("reset \(service) for \(id): exit \(reset.terminationStatus)")
        }
        // A new instance once this one has quit, so the event tap and the checks start clean.
        let again = Process()
        again.executableURL = URL(fileURLWithPath: "/bin/sh")
        again.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? again.run()
        NSApp.terminate(nil)
    }
}

@MainActor
enum SetupWindow {
    private static var window: NSWindow?

    static func show(_ dictation: Dictation) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SetupView().environmentObject(dictation)))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.title = "Welcome to Whisper PTT"
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }
}
