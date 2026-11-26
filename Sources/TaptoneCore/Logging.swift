import OSLog

extension Logger {
    /// Taptone's log, all under one subsystem, so `log stream --predicate 'subsystem == "com.theiskaa.taptone"'`
    /// shows every part of it.
    public init(category: String) {
        self.init(subsystem: "com.theiskaa.taptone", category: category)
    }
}
