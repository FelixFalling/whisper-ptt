import SwiftUI

@main
@MainActor
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--check") {
            exit(Check.run(args))
        }
        if let flag = args.firstIndex(of: "--snapshot"), args.indices.contains(flag + 1) {
            Snapshot.render(into: args[flag + 1])
            exit(0)
        }
        signal(SIGPIPE, SIG_IGN)            // a fallback helper that died must not take the app down
        WhisperPTTApp.main()
    }
}

struct WhisperPTTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var dictation = Dictation.shared

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(dictation)
        } label: {
            Image(systemName: dictation.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Dictation.shared.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Dictation.shared.shutdown()
    }
}
