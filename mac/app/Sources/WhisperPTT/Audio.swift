import AVFoundation

/// Records the default microphone while the key is held. A new engine for each recording
/// follows whatever input is current (AirPods, a USB mic) without stale formats.
final class Recorder {
    enum Failure: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "No microphone is available" }
    }

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var rate = 0.0
    private let lock = NSLock()

    func start() throws {
        stopEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        rate = format.sampleRate
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            self.lock.unlock()
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    /// The recording at Whisper's 16 kHz, mono; empty when nothing was recorded.
    func stop() -> [Float] {
        stopEngine()
        lock.lock()
        let recorded = samples, recordedRate = rate
        samples = []
        lock.unlock()
        return Audio.resample(recorded, from: recordedRate)
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}

enum Audio {
    static let rate = 16_000.0

    static func resample(_ samples: [Float], from source: Double) -> [Float] {
        guard !samples.isEmpty, source > 0, source != rate else { return samples }
        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(
                  pcmFormat: outFormat,
                  frameCapacity: AVAudioFrameCount(Double(samples.count) * rate / source) + 4096)
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        var handedOver = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if handedOver {
                status.pointee = .endOfStream
                return nil
            }
            handedOver = true
            status.pointee = .haveData
            return input
        }
        if let error {
            Log.write("resampling failed: \(error.localizedDescription)")
            return []
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// 16 kHz mono 16-bit WAV, the one format the desktop accepts.
    static func wav(_ samples: [Float]) -> Data {
        let pcm = samples.map { Int16($0.isFinite ? max(-1, min(1, $0)) * 32767 : 0).littleEndian }
        let size = UInt32(pcm.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + size)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                  // format chunk size
        append(UInt16(1))                   // PCM
        append(UInt16(1))                   // mono
        append(UInt32(rate))
        append(UInt32(rate) * 2)            // bytes per second
        append(UInt16(2))                   // bytes per frame
        append(UInt16(16))                  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(size)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
