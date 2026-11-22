import Observation
import TaptoneCore

@Observable @MainActor
final class ActivityModel {
    enum Phase: Equatable {
        case off, starting, listening(hasSound: Bool), preview, failed(String)

        var title: String {
            switch self {
            case .off: "Off"
            case .starting: "Connecting"
            case .listening(true): "Listening"
            case .listening(false): "Waiting for Audio"
            case .preview: "Demo"
            case .failed: "Audio Unavailable"
            }
        }

        var tapAction: String { isLive ? "Stop Taps" : "Start Taps" }

        var isLive: Bool {
            switch self {
            case .starting, .listening: true
            default: false
            }
        }
    }

    var phase = Phase.off
    var history = ActivityHistory()
}
