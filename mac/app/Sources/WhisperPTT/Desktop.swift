import Foundation

/// The desktop, reached over Tailscale. It answers on two ports with the same token:
/// the transcription server (serve() in whisper-ptt.py), which only runs while Whisper is
/// on there, and the remote switch (bin/whisper-control.py), which is always up and turns
/// Whisper on and off.
struct Desktop {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// What the remote switch reports.
    struct Power {
        let host: String
        let active: Bool                // Whisper is switched on there
        let note: String?               // something the desktop wants said about the switch
    }

    let base: URL
    let control: URL
    let token: String

    init?(_ cfg: Config) {
        guard let base = URL(string: cfg.server), let control = cfg.controlURL, !cfg.token.isEmpty
        else { return nil }
        self.base = base
        self.control = control
        self.token = cfg.token
    }

    /// Starts loading the desktop's models while the key is still held.
    func warm(cleanup: Bool, timeout: Double) async throws {
        _ = try await send(base, "warm", body: Data(), cleanup: cleanup, timeout: timeout)
    }

    func transcribe(_ wav: Data, cleanup: Bool, timeout: Double) async throws -> String {
        let reply = try await send(base, "transcribe", body: wav, type: "audio/wav",
                                   cleanup: cleanup, timeout: timeout)
        return (reply["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The desktop's name, for the menu. Answers only while Whisper is on there.
    func health(timeout: Double) async throws -> String {
        let reply = try await send(base, "health", body: nil, timeout: timeout)
        return reply["host"] as? String ?? base.host ?? "the desktop"
    }

    /// Whether Whisper is switched on at the desktop. Answers whenever the desktop is up.
    func state(timeout: Double) async throws -> Power {
        power(try await send(control, "state", body: nil, timeout: timeout))
    }

    /// Switches Whisper on or off at the desktop, as its own Whisper button does.
    func setPower(_ on: Bool, timeout: Double) async throws -> Power {
        let body = try JSONSerialization.data(withJSONObject: ["on": on])
        return power(try await send(control, "power", body: body, type: "application/json",
                                    timeout: timeout))
    }

    private func power(_ reply: [String: Any]) -> Power {
        Power(host: reply["host"] as? String ?? control.host ?? "the desktop",
              active: reply["active"] as? Bool ?? false,
              note: reply["note"] as? String)
    }

    private func send(_ server: URL, _ path: String, body: Data?, type: String? = nil,
                      cleanup: Bool? = nil, timeout: Double) async throws -> [String: Any] {
        // The timeout is how long the desktop may stay silent; it answers only when done.
        var request = URLRequest(url: server.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        if let cleanup {
            request.setValue(cleanup ? "on" : "off", forHTTPHeaderField: "X-Whisper-Cleanup")
        }
        let (data, response) = try await Self.session.data(for: request, delegate: NoRedirects.shared)
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure(errorDescription: reply["error"] as? String ?? "The desktop answered \(status)")
        }
        return reply
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}

/// The desktop never redirects. Following one would hand the token and the recording to
/// wherever it pointed.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
