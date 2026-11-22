import Foundation

/// Keep the order of safety checks and closes testable without loading MultitouchSupport.
enum ProbeResources {
    static func withBuiltIn<Device, Actuator>(
        devices: [Device],
        isBuiltIn: (Device) -> Bool,
        open: (Device) throws -> Actuator?,
        close: (Actuator) -> Int32,
        check: () throws -> Void,
        body: (Actuator) throws -> Void
    ) throws {
        for device in devices {
            try check()
            guard isBuiltIn(device) else { continue }
            try check()
            guard let actuator = try open(device) else { continue }
            let outcome = Result {
                try check()
                try body(actuator)
            }
            let status = close(actuator)
            if status != 0 {
                let prior: String
                if case .failure(let error) = outcome { prior = "\(error.localizedDescription) " }
                else { prior = "" }
                throw ProbeError(message: "\(prior)The driver could not close the actuator (\(status)). Do not rerun the test.")
            }
            return try outcome.get()
        }
        throw ProbeError(message: "No built-in trackpad actuator could be opened. The test does not use external devices.")
    }

    static func submit<Pulse, Output>(
        make: () throws -> Pulse,
        release: (Pulse) -> Void,
        check: () throws -> Void,
        request: (Pulse) throws -> Output
    ) throws -> Output {
        try check()
        let pulse = try make()
        defer { release(pulse) }
        try check()
        return try request(pulse)
    }
}
