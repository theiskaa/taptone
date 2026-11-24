extension Float {
    /// A sample as the analysis expects it: finite and within −1...1.
    var clampedSample: Float { isFinite ? Swift.min(1, Swift.max(-1, self)) : 0 }
}
