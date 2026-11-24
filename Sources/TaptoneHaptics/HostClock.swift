import Darwin

/// The Core Audio host clock (mach absolute time) in nanoseconds, matching capture timestamps.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    @Sendable public static func nowNs() -> UInt64 {
        mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    @Sendable public static func sleep(untilNs deadline: UInt64) {
        let numer = UInt64(timebase.numer), denom = UInt64(timebase.denom)
        mach_wait_until(deadline / numer * denom + deadline % numer * denom / numer)
    }
}
