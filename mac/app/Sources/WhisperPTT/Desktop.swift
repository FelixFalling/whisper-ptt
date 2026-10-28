import Foundation

/// The desktop's transcription server (serve() in whisper-ptt.py), reached over Tailscale.
/// Each request carries the server token, and the Mac's own Cleanup switch.
struct Desktop {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    let base: URL
    let token: String

    init?(_ cfg: Config) {
        guard let base = URL(string: cfg.server), !cfg.token.isEmpty else { return nil }
        self.base = base
        self.token = cfg.token
    }

    /// Starts loading the desktop's models while the key is still held.
    func warm(cleanup: Bool, timeout: Double) async throws {
        _ = try await send("warm", body: Data(), cleanup: cleanup, timeout: timeout)
    }

    func transcribe(_ wav: Data, cleanup: Bool, timeout: Double) async throws -> String {
        let reply = try await send("transcribe", body: wav, cleanup: cleanup, timeout: timeout)
        return (reply["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The desktop's name, for the menu.
    func health(timeout: Double) async throws -> String {
        let reply = try await send("health", body: nil, cleanup: nil, timeout: timeout)
        return reply["host"] as? String ?? base.host ?? "the desktop"
    }

    private func send(_ path: String, body: Data?, cleanup: Bool?, timeout: Double) async throws -> [String: Any] {
        // The timeout is how long the desktop may stay silent; it answers only when done.
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        if let cleanup {
            request.setValue(cleanup ? "on" : "off", forHTTPHeaderField: "X-Whisper-Cleanup")
        }
        let (data, response) = try await Self.session.data(for: request)
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure(errorDescription: reply["error"] as? String ?? "The desktop answered \(status)")
        }
        return reply
    }

    private static let session = URLSession(configuration: .ephemeral)
}
