struct BeatScore {
    let expected: Int
    let detected: Int
    let lags: [Int]

    var misses: Int { expected - lags.count }
    var extras: Int { detected - lags.count }
    var precision: Double? { detected > 0 ? Double(lags.count) / Double(detected) : nil }
    var recall: Double? { expected > 0 ? Double(lags.count) / Double(expected) : nil }

    /// Nearest-rank 95th percentile; keep the sign so early cues aren't reported as late.
    var p95Frames: Int? {
        guard !lags.isEmpty else { return nil }
        return lags.sorted()[(95 * lags.count + 99) / 100 - 1]
    }

    /// Matches each cue and reference at most once. The fixture onsets are farther apart than the match window.
    init(onsets: [Int], cues: [Int], sampleRate: Int) {
        expected = onsets.count
        detected = cues.count
        let early = sampleRate * 10 / 1_000
        let late = sampleRate * 45 / 1_000
        var next = 0
        var matched: [Int] = []
        for onset in onsets {
            while next < cues.count && cues[next] < onset - early { next += 1 }
            if next < cues.count && cues[next] <= onset + late {
                matched.append(cues[next] - onset)
                next += 1
            }
        }
        lags = matched
    }
}
