import CoreAudio
@testable import TaptoneAudio
import Testing

@Suite struct CaptureTeardownTests {
    @Test(arguments: 0...6)
    func releasesOnlyAcquiredResourcesOnceInReverseOrder(acquired: Int) {
        let resources = ["tap", "aggregate", "callback", "route listener", "format listener", "I/O"]
        let expected = Array(resources.prefix(acquired).reversed())
        var teardown = CaptureTeardown()
        var released: [String] = []
        for resource in resources.prefix(acquired) {
            teardown.acquired(resource) { released.append(resource); return noErr }
        }
        #expect(teardown.run().isEmpty)
        #expect(released == expected)
        #expect(teardown.run().isEmpty)
        #expect(released == expected)
    }

    @Test func cleanupErrorsAreReportedWithoutAbandoningEarlierResources() {
        var teardown = CaptureTeardown()
        var released: [String] = []
        teardown.acquired("tap") { released.append("tap"); return -12 }
        teardown.acquired("aggregate") { released.append("aggregate"); return noErr }
        teardown.acquired("callback") { released.append("callback"); return -34 }
        let issues = teardown.run()
        #expect(released == ["callback", "aggregate", "tap"])
        #expect(issues == [.init(operation: "callback", status: -34), .init(operation: "tap", status: -12)])
        #expect(teardown.run().isEmpty)
    }
}
