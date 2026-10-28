import Foundation

/// Transcribes on this Mac when the desktop is away, with mlx-whisper from the Python venv
/// that mac/install.sh sets up. The helper (Resources/fallback.py) keeps running between
/// dictations so its model loads only once.
final class LocalTranscriber: @unchecked Sendable {     // all state is used on `queue`
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private let python: String
    private let script = Bundle.main.url(forResource: "fallback", withExtension: "py")
    private let queue = DispatchQueue(label: "whisper-ptt.fallback")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()

    init(python: String) {
        self.python = python
    }

    var isAvailable: Bool {
        script != nil && FileManager.default.isExecutableFile(atPath: python)
    }

    /// Starts the helper early: importing mlx-whisper takes a few seconds.
    func prepare() {
        queue.async { try? self.launch() }
    }

    func transcribe(_ wav: Data, cfg: Config) async throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-ptt-\(UUID().uuidString).wav")
        try wav.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reply = try await ask(["wav": file.path, "model": cfg.fallbackModel,
                                   "language": cfg.language, "initial_prompt": cfg.initialPrompt])
        return (reply["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checks that the helper starts and mlx-whisper imports, without loading a model.
    func ping() async throws {
        _ = try await ask(["ping": true])
    }

    func shutdown() {
        queue.sync {
            process?.terminate()
            process = nil
        }
    }

    private func ask(_ request: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { done in
            queue.async {
                done.resume(with: Result { try self.exchange(request) })
            }
        }
    }

    private func exchange(_ request: [String: Any]) throws -> [String: Any] {
        try launch()
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        do {
            try input?.write(contentsOf: line)
        } catch {
            reset()
            throw Failure("The transcriber on this Mac stopped; see the log")
        }
        guard let answer = readLine(),
              let reply = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        else {
            reset()
            throw Failure("The transcriber on this Mac stopped; see the log")
        }
        if let error = reply["error"] as? String { throw Failure(error) }
        return reply
    }

    private func launch() throws {
        if let process, process.isRunning { return }
        guard let script, isAvailable else {
            throw Failure("mlx-whisper is not installed on this Mac (run mac/install.sh)")
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: python)
        helper.arguments = ["-u", script.path]
        let stdin = Pipe(), stdout = Pipe()
        helper.standardInput = stdin
        helper.standardOutput = stdout
        helper.standardError = Log.handle ?? FileHandle.nullDevice
        try helper.run()
        process = helper
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        pending = Data()
        Log.write("started the transcriber on this Mac (\(python))")
    }

    private func readLine() -> Data? {
        guard let output else { return nil }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let end = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<end])
                pending = Data(pending[pending.index(after: end)...])
                return line
            }
            // read(2) returns whatever has arrived; FileHandle.read(upToCount:) would wait
            // for all 64 KB.
            let count = read(output.fileDescriptor, &chunk, chunk.count)
            guard count > 0 else { return nil }         // the helper exited
            pending.append(contentsOf: chunk[0..<count])
        }
    }

    private func reset() {
        process?.terminate()
        process = nil
    }
}
