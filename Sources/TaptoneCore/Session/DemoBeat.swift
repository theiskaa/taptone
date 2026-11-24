import Foundation

/// A silent, deterministic fixture for exercising the real detector without audio access.
public struct DemoBeat {
    public static let sampleRate = 48_000.0
    package let framesPerBeat: Int
    private var frame = 0

    public init(bpm: Double = 120) {
        precondition(bpm.isFinite && (30...300).contains(bpm))
        framesPerBeat = Int(Self.sampleRate * 60 / bpm)
    }

    public mutating func nextSample() -> Float {
        let beatFrame = frame % framesPerBeat
        frame += 1
        guard beatFrame < Int(Self.sampleRate * 0.11) else { return 0 }
        let time = Double(beatFrame) / Self.sampleRate
        return Float(0.85 * sin(2 * .pi * 85 * time) * exp(-time * 38))
    }
}
