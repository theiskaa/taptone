import CoreAudio

public struct CaptureCleanupIssue: Equatable, Sendable {
    public let operation: String
    public let status: OSStatus
}

/// Register cleanup only after acquisition succeeds. Attempt every release in reverse order, even after an error.
struct CaptureTeardown {
    private var releases: [(operation: String, perform: () -> OSStatus)] = []

    mutating func acquired(_ operation: String, release: @escaping () -> OSStatus) {
        releases.append((operation, release))
    }

    mutating func run() -> [CaptureCleanupIssue] {
        var issues: [CaptureCleanupIssue] = []
        while let release = releases.popLast() {
            let status = release.perform()
            if status != noErr { issues.append(CaptureCleanupIssue(operation: release.operation, status: status)) }
        }
        return issues
    }
}
