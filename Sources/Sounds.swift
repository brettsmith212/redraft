import AVFoundation

/// Small synthesized sounds. Cycling alternates plays a soft, warm tick;
/// landing back on the original plays it lower, so you can hear when you're
/// home. Deleting an alternate pops.
@MainActor
final class Sounds {
    enum Sound { case alternate, original, pop }

    static let shared = Sounds()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var started = false
    private var cache: [Sound: AVAudioPCMBuffer] = [:]

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool ?? true
    }

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ sound: Sound) {
        guard Self.enabled, let buffer = buffer(for: sound) else { return }
        if !started {
            do { try engine.start() } catch { return }
            started = true
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    #if DEBUG
    /// Writes every sound to WAV files for inspection.
    func debugRenderAll(to folder: String) {
        for (sound, name) in [(Sound.alternate, "next"), (.original, "original"), (.pop, "pop")] {
            guard let buffer = buffer(for: sound) else { continue }
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).wav")
            if let file = try? AVAudioFile(forWriting: url, settings: format.settings) { try? file.write(from: buffer) }
        }
    }
    #endif

    private func buffer(for sound: Sound) -> AVAudioPCMBuffer? {
        if let cached = cache[sound] { return cached }
        let samples: [Float]
        switch sound {
        case .pop: samples = Synth.pop(rate: format.sampleRate)
        case .alternate: samples = Synth.tick(high: true, rate: format.sampleRate)
        case .original: samples = Synth.tick(high: false, rate: format.sampleRate)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        cache[sound] = buffer
        return buffer
    }
}

private enum Synth {
    /// A quiet, rounded sine blip: A5 for "next", D5 for "back to the original".
    static func tick(high: Bool, rate: Double) -> [Float] {
        let f: Double = high ? 880 : 587.3
        return normalize(sampled(0.1, rate) { t in
            min(1, t / 0.005) * exp(-t / 0.03) * (sin(2 * .pi * f * t) + 0.1 * sin(4 * .pi * f * t))
        }, peak: 0.17)
    }

    static func pop(rate: Double) -> [Float] {
        var seed: UInt64 = 0x5EED
        return normalize(sampled(0.22, rate) { t in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let n = Double(Int64(bitPattern: seed >> 1) % 10_000) / 10_000
            let thump = sin(2 * .pi * (190 - 400 * t) * t) * exp(-t / 0.05)
            return 0.75 * thump + 0.35 * n * exp(-t / 0.03)
        }, peak: 0.28)
    }

    private static func sampled(_ duration: Double, _ rate: Double, _ f: (Double) -> Double) -> [Float] {
        (0..<Int(duration * rate)).map { Float(f(Double($0) / rate)) }
    }

    private static func normalize(_ samples: [Float], peak: Float) -> [Float] {
        let maxValue = samples.map(abs).max() ?? 0
        guard maxValue > 0 else { return samples }
        let scale = peak / maxValue
        return samples.map { $0 * scale }
    }
}
