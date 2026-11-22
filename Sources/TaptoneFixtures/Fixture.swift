import Foundation
import TaptoneCore

/// The detector is tested on the same quantized samples that are written to disk.
struct Fixture {
    static let sampleRate = Int(DemoBeat.sampleRate)
    private static let preroll = sampleRate
    private static let trailingSilence = sampleRate

    let name: String
    let onsets: [Int]
    let pcm: [Int16] // Interleaved stereo.

    static func kicks(bpm: Int, antiPhase: Bool = false) -> Self {
        var beat = DemoBeat(bpm: Double(bpm))
        let interval = beat.framesPerBeat
        let count = 20
        return Fixture(name: "kick-\(bpm)" + (antiPhase ? "-antiphase" : ""),
                       onsets: (0..<count).map { preroll + $0 * interval },
                       frameCount: preroll + count * interval + trailingSilence) { frame in
            guard (preroll..<preroll + count * interval).contains(frame) else { return (0, 0) }
            let sample = beat.nextSample()
            return (sample, antiPhase ? -sample : sample)
        }
    }

    static var silence: Self {
        Fixture(name: "silence", onsets: [], frameCount: 4 * sampleRate) { _ in (0, 0) }
    }

    static var heldBass: Self {
        Fixture(name: "held-bass", onsets: [preroll], frameCount: 4 * sampleRate) { frame in
            guard (preroll..<3 * sampleRate).contains(frame) else { return (0, 0) }
            let time = Double(frame - preroll) / Double(sampleRate)
            let sample = Float(0.35 * sin(2 * .pi * 75 * time))
            return (sample, sample)
        }
    }

    static var upperBandBursts: Self {
        Fixture(name: "upper-band-bursts", onsets: [], frameCount: 6 * sampleRate) { frame in
            guard (preroll..<5 * sampleRate).contains(frame) else { return (0, 0) }
            let time = Double((frame - preroll) % (sampleRate / 4)) / Double(sampleRate)
            guard time < 0.06 else { return (0, 0) }
            let envelope = sin(.pi * time / 0.06)
            let sample = Float(0.18 * envelope * (sin(2 * .pi * 880 * time) + sin(2 * .pi * 1_730 * time)))
            return (sample, sample)
        }
    }

    private init(name: String, onsets: [Int], frameCount: Int, sample: (Int) -> (Float, Float)) {
        self.name = name
        self.onsets = onsets
        var frames: [Int16] = []
        frames.reserveCapacity(frameCount * 2)
        for frame in 0..<frameCount {
            let (left, right) = sample(frame)
            frames.append(Self.quantize(left))
            frames.append(Self.quantize(right))
        }
        pcm = frames
    }

    private static func quantize(_ sample: Float) -> Int16 {
        Int16((min(1, max(-1, sample)) * Float(Int16.max)).rounded())
    }

    func detect(sensitivity: BeatDetector.Sensitivity) -> [Int] {
        var detector = BeatDetector(sampleRate: Double(Self.sampleRate))
        detector.sensitivity = sensitivity
        let scale = 1 / Float(Int16.max)
        var cues: [Int] = []
        for index in stride(from: 0, to: pcm.count, by: 2) {
            let reading = detector.push(left: Float(pcm[index]) * scale, right: Float(pcm[index + 1]) * scale)
            if reading?.isBeat == true { cues.append(index / 2) }
        }
        return cues
    }

    var waveData: Data {
        var bytes = Data()
        bytes.reserveCapacity(44 + pcm.count * 2)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        let pcmBytes = UInt32(pcm.count * 2)
        bytes.append(contentsOf: "RIFF".utf8)
        appendLE(36 + pcmBytes)
        bytes.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(UInt32(16)) // PCM format chunk size.
        appendLE(UInt16(1))  // Linear PCM.
        appendLE(UInt16(2))  // Stereo.
        appendLE(UInt32(Self.sampleRate))
        appendLE(UInt32(Self.sampleRate * 4))
        appendLE(UInt16(4))  // Bytes per frame.
        appendLE(UInt16(16)) // Bits per sample.
        bytes.append(contentsOf: "data".utf8)
        appendLE(pcmBytes)
        for value in pcm { appendLE(value) }
        return bytes
    }
}
