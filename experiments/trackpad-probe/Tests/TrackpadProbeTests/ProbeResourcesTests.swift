@testable import TaptoneTrackpadProbe
import Testing

@Suite struct ProbeResourcesTests {
    @Test func skipsExternalDevicesAndClosesExactlyOnceAfterFailure() {
        var opened: [String] = []
        var closed: [String] = []
        #expect(throws: ProbeError.self) {
            try ProbeResources.withBuiltIn(devices: ["external", "built-in", "another"],
                                           isBuiltIn: { $0 != "external" }, open: { device in
                opened.append(device)
                return device
            }, close: { actuator in
                closed.append(actuator)
                return 0
            }, check: {}) { _ in throw ProbeError(message: "request failed") }
        }
        #expect(opened == ["built-in"])
        #expect(closed == ["built-in"])
    }

    @Test func cancellationDuringDeviceSelectionPreventsOpening() {
        var stopped = false
        var opens = 0
        #expect(throws: ProbeError.self) {
            try ProbeResources.withBuiltIn(devices: [1], isBuiltIn: { _ in
                stopped = true
                return true
            }, open: { device in
                opens += 1
                return device
            }, close: { _ in 0 }, check: {
                if stopped { throw ProbeError(message: "cancelled") }
            }, body: { _ in })
        }
        #expect(opens == 0)
    }

    @Test func cancellationDuringWaveformCreationReleasesWithoutRequesting() {
        var stopped = false
        var released: [Int] = []
        var requested: [Int] = []
        #expect(throws: ProbeError.self) {
            try ProbeResources.submit(make: {
                stopped = true
                return 1
            }, release: { released.append($0) }, check: {
                if stopped { throw ProbeError(message: "cancelled") }
            }, request: { requested.append($0) })
        }
        #expect(released == [1])
        #expect(requested.isEmpty)
    }
}
