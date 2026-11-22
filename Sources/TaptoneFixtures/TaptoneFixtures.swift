import Foundation
import TaptoneCore

@main
struct TaptoneFixtures {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print("Usage: swift run TaptoneFixtures [output directory; default .build/fixtures]")
            return
        }
        guard args.count <= 1, args.first?.hasPrefix("-") != true else {
            fail("Expected at most one output directory. See --help.")
        }
        let output = URL(fileURLWithPath: args.first ?? ".build/fixtures", isDirectory: true)
        do {
            try generate(into: output)
            print(output.path)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func generate(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = [Fixture.kicks(bpm: 90), .kicks(bpm: 120), .kicks(bpm: 150), .kicks(bpm: 120, antiPhase: true),
                        .heldBass, .upperBandBursts, .silence]
        var report = "fixture,sensitivity,expected,detected,misses,extras,precision,recall,p95_lag_frames,p95_lag_ms\n"
        for fixture in fixtures {
            let wave = directory.appendingPathComponent("\(fixture.name).wav")
            try fixture.waveData.write(to: wave, options: .atomic)
            let labelFile = directory.appendingPathComponent("\(fixture.name).onsets.csv")
            let labels = "frame,sample_rate_hz\n" + fixture.onsets.map { "\($0),\(Fixture.sampleRate)\n" }.joined()
            try labels.write(to: labelFile, atomically: true, encoding: .utf8)
            for sensitivity in BeatDetector.Sensitivity.allCases {
                let cues = fixture.detect(sensitivity: sensitivity)
                let score = BeatScore(onsets: fixture.onsets, cues: cues, sampleRate: Fixture.sampleRate)
                let lag = score.p95Frames.map { Double($0) * 1_000 / Double(Fixture.sampleRate) }
                let row = [fixture.name, sensitivity.rawValue, String(score.expected), String(score.detected),
                           String(score.misses), String(score.extras), decimal(score.precision), decimal(score.recall),
                           score.p95Frames.map(String.init) ?? "", decimal(lag)]
                report += row.joined(separator: ",") + "\n"
            }
        }
        try report.write(to: directory.appendingPathComponent("metrics.csv"), atomically: true, encoding: .utf8)
    }

    private static func decimal(_ value: Double?) -> String {
        value.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("TaptoneFixtures: \(message)\n".utf8))
        exit(1)
    }
}
