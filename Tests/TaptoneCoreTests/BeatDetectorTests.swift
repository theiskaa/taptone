import Foundation
import TaptoneCore
import Testing

@Suite struct BeatDetectorTests {
    @Test(arguments: [90.0, 120.0, 150.0])
    func detectsFixtureOnsets(bpm: Double) {
        let rate = Int(DemoBeat.sampleRate)
        let interval = Int(Double(rate) * 60 / bpm)
        var demo = DemoBeat(bpm: bpm)
        let beats = detect(sampleRate: rate, count: interval * 12) { _ in
            let sample = demo.nextSample()
            return (sample, -sample) // Deliberately out of phase.
        }
        #expect(beats.count == 12)
        for (index, frame) in beats.enumerated() {
            #expect((0...rate / 20).contains(frame - index * interval))
        }
    }

    @Test func silenceAndInvalidSamplesStayQuiet() {
        var detector = BeatDetector(sampleRate: 48_000)
        for frame in 0..<48_000 {
            if let reading = detector.push(left: frame.isMultiple(of: 3) ? .nan : 0, right: -.infinity) {
                #expect(!reading.isBeat)
                #expect(reading.levelDBFS == -90)
            }
        }
    }

    @Test(arguments: [44_100, 48_000, 96_000])
    func heldBassDoesNotRetrigger(sampleRate: Int) {
        let beats = detect(sampleRate: sampleRate, count: sampleRate * 3) { frame in
            let sample = Float(sin(2 * .pi * 75 * Double(frame) / Double(sampleRate)) * 0.35)
            return (sample, sample)
        }
        #expect(beats.count == 1)
    }

    @Test func sensitivityChangesDetectionThreshold() {
        func hits(_ sensitivity: BeatDetector.Sensitivity) -> Int {
            let rate = Int(DemoBeat.sampleRate)
            var demo = DemoBeat()
            return detect(sampleRate: rate, count: rate, sensitivity: sensitivity) { _ in
                let sample = demo.nextSample() * 0.02
                return (sample, sample)
            }.count
        }
        #expect(hits(.high) == 2)
        #expect(hits(.low) == 0)
    }

    private func detect(sampleRate: Int, count: Int, sensitivity: BeatDetector.Sensitivity = .normal,
                        sample: (Int) -> (Float, Float)) -> [Int] {
        var detector = BeatDetector(sampleRate: Double(sampleRate))
        detector.sensitivity = sensitivity
        return (0..<count).compactMap { frame in
            let (left, right) = sample(frame)
            return detector.push(left: left, right: right)?.isBeat == true ? frame : nil
        }
    }
}
