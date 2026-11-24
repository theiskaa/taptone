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

        var isLive: Bool {
            switch self {
            case .starting, .listening: true
            default: false
            }
        }
    }

    enum KickTestState: Equatable {
        case idle, running(sent: Int), finished, failed
    }

    struct Note: Equatable {
        let name: String
        let hertz: Double
    }

    var phase = Phase.off
    /// Paused from the switch: stays off until resumed or relaunched.
    var isPaused = false
    var history = ActivityHistory()
    /// Kicks play on the trackpad motor rather than as AppKit taps.
    var usesMotor = false
    var device: OutputDevice?
    /// The motor's live state, refreshed a dozen times a second while listening.
    private(set) var live: HapticPlayer.Reading?
    /// The bass note on show. The player already holds a note through a moment without pitch.
    private(set) var note: Note?
    var kickTest = KickTestState.idle

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
        case .off: isPaused ? "Paused" : "Not listening"
        case .starting: "Connecting…"
        case .listening(true): usesMotor ? "Listening" : "Standard taps"
        case .listening(false): "Waiting for audio"
        case .preview: "Demo"
        case .failed(_, true): "Can’t hear system audio"
        case .failed(_, false): "Stopped"
        }
    }

    /// The title with the output it applies to, for the menu.
    var summary: String {
        switch phase {
        case .starting, .listening: device.map { "\(title) on \($0.name)" } ?? title
        case .preview: "Demo, no haptics"
        default: title
        }
    }

    var needsAudioAccess: Bool {
        if case .failed(_, true) = phase { true } else { false }
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
