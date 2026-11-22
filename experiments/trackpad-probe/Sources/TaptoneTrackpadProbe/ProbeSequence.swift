import Foundation

struct ProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ProbeMode: Equatable {
    case dryRun, check, run, live, help

    init(arguments: [String]) throws {
        switch arguments {
        case [], ["--dry-run"]: self = .dryRun
        case ["--check"]: self = .check
        case ["--run"]: self = .run
        case ["--live"]: self = .live
        case ["--help"], ["-h"]: self = .help
        default: throw ProbeError(message: "Use one of --dry-run, --check, --run, --live, or --help.")
        }
    }
}

/// A fixed test, not a general-purpose actuator player. It allows no custom pulse parameters.
enum ProbeSequence {
    enum Strength: String {
        case gentle, firmer

        var level: Float {
            switch self {
            case .gentle: 0.20
            case .firmer: 0.40
            }
        }
    }

    static let frequencyHz = 200.0
    static let durationMs = 20
    static let leadInSeconds = 2
    static let gapSeconds = 1
    static let strengths: [Strength] = [.gentle, .gentle, .firmer, .firmer]
    static let nominalTimes = strengths.indices.map { leadInSeconds + $0 * gapSeconds }

    static func run(
        wait: (Double) throws -> Void,
        check: () throws -> Void,
        request: (Strength) throws -> Void
    ) throws {
        for (index, strength) in strengths.enumerated() {
            try wait(Double(index == 0 ? leadInSeconds : gapSeconds))
            try check()
            try request(strength)
        }
        // Let the last short pulse finish before closing the actuator.
        try wait(Double(durationMs) / 1_000)
    }
}
