import Foundation

/// Arithmetic mean of the RSSI window, truncated toward zero.
/// Matches the prior `Int(mean)` behaviour of the vDSP implementation while removing
/// the Accelerate dependency, and is the basis of the unlock-debounce decision.
func meanRSSI(_ samples: [Double]) -> Int {
    guard !samples.isEmpty else { return 0 }
    return Int(samples.reduce(0, +) / Double(samples.count))
}

/// Pure gate for the unlock / presence transition.
///
/// A lone RSSI spike cannot flip presence: the *smoothed* value must cross the threshold,
/// the window must already hold at least `minSamples` readings, and we only unlock when
/// not already present.
func shouldUnlock(estimatedRSSI: Int,
                  sampleCount: Int,
                  unlockThreshold: Int,
                  minSamples: Int,
                  isPresent: Bool) -> Bool {
    return !isPresent && sampleCount >= minSamples && estimatedRSSI >= unlockThreshold
}
