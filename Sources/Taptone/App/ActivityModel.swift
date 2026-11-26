import Foundation
import Observation
import TaptoneAudio
import TaptoneCore
import TaptoneHaptics

/// Everything the menu, the main window, and the welcome window display.
@Observable @MainActor
final class ActivityModel {
    enum Phase: Equatable {
        /// `needsAccess`: allowing system audio recording would likely fix the failure.
        case off, starting, listening(hasSound: Bool), preview, failed(String, needsAccess: Bool)
        /// The Mac has no Force Touch trackpad to play on.
        case noTrackpad

        var isLive: Bool {
            switch self {
            case .starting, .listening: true
            default: false
            }
        }
    }

    enum KickTestState: Equatable {
        case idle, running(sent: Int), finished, failed, noTrackpad
    }

    struct Note: Equatable {
        let name: String
        let hertz: Double
    }

    var phase = Phase.off
    /// When the pause from the switch ends: `.distantFuture` until resumed, nil when not paused.
    var pausedUntil: Date?
    var isPaused: Bool { pausedUntil != nil }
    /// Paused by itself while an app uses the microphone; listening picks up again after.
    var inCall = false
    var history = ActivityHistory()
    /// Kicks play on the trackpad motor rather than as AppKit taps.
    var usesMotor = false
    var device: OutputDevice?
    /// The motor's live state, refreshed a dozen times a second while listening.
    private(set) var live: HapticPlayer.Reading?
    /// The bass note on show. The player already holds a note through a moment without pitch.
    private(set) var note: Note?
    var kickTest = KickTestState.idle
    /// A newer version on GitHub, once a check finds one.
    var availableUpdate: UpdateChecker.Release?
    /// Listening, but every sample so far was exactly zero: maybe macOS withholds system audio.
    var hearsOnlySilence = false
    /// The pause shortcut is on, but another app already owns it.
    var shortcutTaken = false

    func update(live reading: HapticPlayer.Reading?) {
        live = reading
        guard case .listening(true) = phase, usesMotor, let reading, reading.body >= HapticSynth.bodyGate,
              let pitch = reading.pitchHz else {
            note = nil
            return
        }
        note = Note(name: Self.noteName(pitch), hertz: pitch)
    }

    var title: String {
        switch phase {
        case .off where isPaused: "Paused"
        case .off where inCall: "Paused for a call"
        case .off: "Not listening"
        case .starting: "Starting…"
        case .listening(true): usesMotor ? "Listening" : "Listening, taps only"
        case .listening(false) where hearsOnlySilence: "Hearing only silence"
        case .listening(false): "Waiting for audio"
        case .preview: "Demo"
        case .failed(_, true): "Can’t hear system audio"
        case .failed(_, false): "Stopped listening"
        case .noTrackpad: "No Force Touch trackpad"
        }
    }

    /// The title with the output it applies to, or how long a pause lasts, for the menu.
    var summary: String {
        switch phase {
        case .starting, .listening: device.map { "\(title) on \($0.name)" } ?? title
        case .preview: "Demo, no haptics"
        case .off: pauseEnd.map { "Paused until \($0)" } ?? title
        default: title
        }
    }

    /// The time a timed pause ends, as the clock shows it.
    var pauseEnd: String? {
        guard let pausedUntil, pausedUntil != .distantFuture else { return nil }
        return pausedUntil.formatted(date: .omitted, time: .shortened)
    }

    var needsAudioAccess: Bool {
        switch phase {
        case .failed(_, true): true
        case .listening(false): hearsOnlySilence
        default: false
        }
    }

    /// 0...1 for drawing without the motor: each kick swells and fades.
    func kickLevel(now: UInt64) -> Double {
        guard let lastKick = history.lastKickNs, now >= lastKick else { return 0 }
        return 0.85 * exp(-Double(now - lastKick) / 1e9 / 0.25)
    }

    static func noteName(_ hertz: Double) -> String {
        let midi = Int((69 + 12 * log2(hertz / 440)).rounded())
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[((midi % 12) + 12) % 12] + String(midi / 12 - 1)
    }
}

extension HapticPlayer.Reading {
    /// The motor level that fills the app's drawings: a medium kick.
    static let fullScaleLevel: Float = 0.6

    /// The motor level as the app draws it, 0...1.
    var shownLevel: Double { Double(min(1, level / Self.fullScaleLevel)) }
}
