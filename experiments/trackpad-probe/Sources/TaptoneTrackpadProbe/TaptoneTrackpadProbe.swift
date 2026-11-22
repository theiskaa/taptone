import Darwin
import Foundation
import os

@main
struct TaptoneTrackpadProbe {
    static func main() {
        let mode: ProbeMode
        do {
            mode = try ProbeMode(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            write(error.localizedDescription, to: .standardError)
            exit(64)
        }
        do {
            switch mode {
            case .help:
                write("""
                Usage: TaptoneTrackpadProbe [--dry-run | --check | --run | --live]
                --dry-run  Print the fixed sequence without loading the system framework (default).
                --check    Resolve the private symbols without selecting a device.
                --run      Request four short pulses on a built-in trackpad from a foreground terminal.
                --live     Listen to system audio and request bounded firmer pulses on bass accents.
                """)
            case .dryRun:
                write("Dry run: no framework loaded, no pulses requested.")
                for (time, strength) in zip(ProbeSequence.nominalTimes, ProbeSequence.strengths) {
                    write("+\(time)s · \(strength.rawValue) · \(ProbeSequence.durationMs) ms at \(Int(ProbeSequence.frequencyHz)) Hz · level \(strength.level)")
                }
            case .check:
                _ = try MultitouchActuator()
                write("Required private symbols are present. No device was opened and no pulses were requested.")
            case .run, .live:
                try withStopCheck { check in
                    if mode == .live { try LiveProbe.run(checkStop: check, write: { write($0) }) }
                    else { try runOnTrackpad(checkStop: check) }
                }
            }
        } catch {
            write("Trackpad probe: \(error.localizedDescription)", to: .standardError)
            exit(1)
        }
    }

    private static func withStopCheck(_ run: (@escaping () throws -> Void) throws -> Void) throws {
        guard isForegroundTerminal else {
            throw ProbeError(message: "This mode requires a foreground interactive terminal. No capture or actuator was opened.")
        }
        let signals = StopSignals()
        try run {
            if signals.shouldStop { throw ProbeError(message: "Stopped by signal.") }
            guard isForegroundTerminal else { throw ProbeError(message: "The probe lost its foreground terminal.") }
        }
    }

    private static func runOnTrackpad(checkStop: @escaping () throws -> Void) throws {
        let clock = ContinuousClock()
        let expires = clock.now + .seconds(6)
        func check() throws {
            try checkStop()
            guard clock.now < expires else { throw ProbeError(message: "The test time window expired.") }
        }
        func wait(_ seconds: Double) throws {
            let until = clock.now + .seconds(seconds)
            while clock.now < until {
                try check()
                Thread.sleep(forTimeInterval: 0.01)
            }
            try check()
        }

        try check()
        let actuator = try MultitouchActuator()
        try actuator.withBuiltInActuator(check: check) { request in
            write("Rest one fingertip on the built-in trackpad. First pulse in two seconds: two gentle, then two firmer. Press Ctrl-C if uncomfortable.")
            var number = 0
            try ProbeSequence.run(wait: wait, check: check) { strength in
                _ = try request(strength) { true }
                number += 1
                write("\(number)/\(ProbeSequence.strengths.count) requested · \(strength.rawValue)")
            }
        }
        write("Finished. The driver accepted four requests; that does not confirm all four were felt.")
    }

    private static var isForegroundTerminal: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 && tcgetpgrp(STDIN_FILENO) == getpgrp()
    }

    private static func write(_ line: String, to stream: FileHandle = .standardOutput) {
        stream.write(Data((line + "\n").utf8))
    }
}

/// A signal cancels future requests. A pulse already sent to the driver is at most 20 ms nominal.
private final class StopSignals {
    private let requested = OSAllocatedUnfairLock(initialState: false)
    private let sources: [DispatchSourceSignal]

    init() {
        let flag = requested
        let queue = DispatchQueue(label: "com.theiskaa.taptone.trackpad-probe.signals")
        sources = [SIGINT, SIGTERM, SIGHUP, SIGTSTP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { flag.withLock { $0 = true } }
            source.resume()
            return source
        }
    }

    var shouldStop: Bool { requested.withLock { $0 } }

    deinit { for source in sources { source.cancel() } }
}
