import AVFoundation

/// Synthesizes realistic dice and coin sounds: a deep knock when a die hits
/// the box wall, a soft tap when it hits the floor, a continuous slide/scrape
/// while dice are moving, and a distinctive ring for the coin.
final class SoundSynth {
    static let shared = SoundSynth()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var wallKnockBuffers: [AVAudioPCMBuffer] = []
    private var floorTapBuffers: [AVAudioPCMBuffer] = []
    private var nextPlayer = 0
    private var prepared = false

    // Recorded coin sound, played on its own node since it's decoded at the
    // file's native format rather than the synth pool's shared 44.1kHz mono.
    private let coinPlayer = AVAudioPlayerNode()
    private var coinBuffer: AVAudioPCMBuffer?

    // Dedicated always-looping player for the continuous slide/scrape sound —
    // kept separate from the round-robin impact pool and just modulated in volume.
    private let slidePlayer = AVAudioPlayerNode()
    private var slideCurrentVolume: Float = 0

    private let sampleRate: Double = 44_100

    private init() {}

    func prepare() {
        guard !prepared else { return }
        prepared = true

        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        for _ in 0..<8 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        // Hollow wooden box-wall knocks — deeper and longer than floor taps.
        wallKnockBuffers = (0..<6).map { i in
            let freq = 210 + Double(i) * 32
            let damping = 0.978 + Double(i) * 0.0018
            return makeWallKnock(frequency: freq, damping: damping, format: format)
        }
        // Short, soft taps for the floor of the box.
        floorTapBuffers = (0..<8).map { i in
            let freq = 900 + Double(i) * 140
            let damping = 0.96 + Double(i) * 0.002
            return makeFloorTap(frequency: freq, damping: damping, format: format)
        }
        engine.attach(slidePlayer)
        engine.connect(slidePlayer, to: engine.mainMixerNode, format: format)
        let slideLoop = makeSlideLoop(format: format)

        if let url = Bundle.main.url(forResource: "CoinThrow", withExtension: "mp3"),
           let file = try? AVAudioFile(forReading: url),
           let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) {
            try? file.read(into: buffer)
            coinBuffer = buffer
            engine.attach(coinPlayer)
            engine.connect(coinPlayer, to: engine.mainMixerNode, format: file.processingFormat)
        }

        do {
            try engine.start()
            players.forEach { $0.play() }
            slidePlayer.volume = 0
            slidePlayer.scheduleBuffer(slideLoop, at: nil, options: .loops, completionHandler: nil)
            slidePlayer.play()
            if coinBuffer != nil { coinPlayer.play() }
        } catch {
            prepared = false
        }
    }

    /// Continuous scrape of dice sliding across the wood floor. `intensity` is
    /// the combined horizontal speed of every grounded die (0 = silent); call
    /// every frame while dice are moving. Smoothed internally so the loop's
    /// volume swells and fades instead of snapping, and scales up naturally
    /// with more dice since intensity is a sum across the whole pool.
    func updateSlide(intensity: Float) {
        guard prepared, engine.isRunning else { return }
        let target = min(intensity / 5.0, 1.0) * 0.45
        slideCurrentVolume += (target - slideCurrentVolume) * 0.2
        slidePlayer.volume = max(0, slideCurrentVolume)
    }

    /// Deep hollow knock when a die strikes the wooden box wall (border).
    func wallKnock(volume: Float) {
        guard prepared, engine.isRunning, !wallKnockBuffers.isEmpty else { return }
        let buffer = wallKnockBuffers.randomElement()!
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = min(0.4 + 0.6 * volume, 1.0)
        player.scheduleBuffer(buffer)
    }

    /// Short soft tap when a die strikes the floor of the box.
    func floorTap(volume: Float) {
        guard prepared, engine.isRunning, !floorTapBuffers.isEmpty else { return }
        let buffer = floorTapBuffers.randomElement()!
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = min(0.2 + 0.5 * volume, 0.85)
        player.scheduleBuffer(buffer)
    }

    /// Recorded coin-toss sound. `.interrupts` lets a fresh toss cut off one
    /// still playing rather than overlapping two copies of the same clip.
    func coinRing() {
        guard prepared, engine.isRunning, let buffer = coinBuffer else { return }
        coinPlayer.stop()
        coinPlayer.volume = 0.85
        coinPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        coinPlayer.play()
    }

    // MARK: - Buffer synthesis

    /// Soft continuous scrape/rumble loop — filtered noise, crossfaded at the
    /// seam so it can repeat forever without a click. Volume is controlled
    /// entirely by `updateSlide`; this buffer itself just plays at a flat level.
    private func makeSlideLoop(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let duration = 1.2
        let frames = Int(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData![0]

        var raw = [Double](repeating: 0, count: frames)
        for n in 0..<frames { raw[n] = Double.random(in: -1...1) }

        func lowpass(_ input: [Double], alpha: Double) -> [Double] {
            var out = [Double](repeating: 0, count: input.count)
            var prev = 0.0
            for i in 0..<input.count {
                prev += alpha * (input[i] - prev)
                out[i] = prev
            }
            return out
        }
        var filtered = lowpass(raw, alpha: 0.12)
        filtered = lowpass(filtered, alpha: 0.35)

        let peak = filtered.map { abs($0) }.max() ?? 1
        let gain = peak > 0 ? 0.8 / peak : 1

        // Crossfade the tail into the head so the loop has no seam click.
        let fadeFrames = Int(sampleRate * 0.08)
        for n in 0..<frames {
            var sample = filtered[n] * gain
            if n < fadeFrames {
                let t = Double(n) / Double(fadeFrames)
                let tailSample = filtered[frames - fadeFrames + n] * gain
                sample = tailSample * (1 - t) + sample * t
            }
            data[n] = Float(sample)
        }
        return buffer
    }

    /// Hollow wooden box-wall knock: sharp rap transient + low resonant body.
    private func makeWallKnock(frequency: Double, damping: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let duration = 0.22
        let frames = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]

        let r = damping
        let w = 2 * Double.pi * frequency / sampleRate
        let a1 = 2 * r * cos(w)
        let a2 = -r * r
        let exciteFrames = Int(sampleRate * 0.010)
        var y1 = 0.0, y2 = 0.0
        var peak = 0.0
        var samples = [Double](repeating: 0, count: Int(frames))

        for n in 0..<Int(frames) {
            let t = Double(n) / sampleRate
            var excite = 0.0
            if n < exciteFrames {
                let fade = pow(1 - Double(n) / Double(exciteFrames), 1.2)
                excite = Double.random(in: -1...1) * fade
            }
            let y = excite + a1 * y1 + a2 * y2
            y2 = y1
            y1 = y
            let envelope = exp(-t * 20)
            let thump = sin(2 * .pi * 95 * t) * exp(-t * 34) * 0.5
            samples[n] = y * envelope + thump
            peak = max(peak, abs(samples[n]))
        }
        let gain = peak > 0 ? 0.85 / peak : 1
        for n in 0..<Int(frames) { data[n] = Float(samples[n] * gain) }
        return buffer
    }

    /// Short soft floor tap: quick resonant click, lighter than a wall knock.
    private func makeFloorTap(frequency: Double, damping: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let duration = 0.07
        let frames = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]

        let r = damping
        let w = 2 * Double.pi * frequency / sampleRate
        let a1 = 2 * r * cos(w)
        let a2 = -r * r
        let exciteFrames = Int(sampleRate * 0.004)
        var y1 = 0.0, y2 = 0.0
        var peak = 0.0
        var samples = [Double](repeating: 0, count: Int(frames))

        for n in 0..<Int(frames) {
            let t = Double(n) / sampleRate
            var excite = 0.0
            if n < exciteFrames {
                let fade = pow(1 - Double(n) / Double(exciteFrames), 1.4)
                excite = Double.random(in: -1...1) * fade
            }
            let y = excite + a1 * y1 + a2 * y2
            y2 = y1
            y1 = y
            let envelope = exp(-t * 60)
            samples[n] = y * envelope
            peak = max(peak, abs(samples[n]))
        }
        let gain = peak > 0 ? 0.7 / peak : 1
        for n in 0..<Int(frames) { data[n] = Float(samples[n] * gain) }
        return buffer
    }
}
