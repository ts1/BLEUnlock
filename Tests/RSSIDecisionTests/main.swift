import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}

// meanRSSI — arithmetic mean, truncated toward zero (matches prior Int(mean)).
check(meanRSSI([]) == 0, "mean of empty window is 0")
check(meanRSSI([-50, -50, -50]) == -50, "mean of equal samples")
check(meanRSSI([-85, -85, -85, -85, -40]) == -76, "a lone -40 spike only pulls the mean to -76")

// shouldUnlock — a lone spike must NOT unlock; sustained signal must.
check(shouldUnlock(estimatedRSSI: -76, sampleCount: 5, unlockThreshold: -60, minSamples: 3, isPresent: false) == false,
      "smoothed -76 < threshold -60 -> no unlock (spike rejected)")
check(shouldUnlock(estimatedRSSI: -55, sampleCount: 3, unlockThreshold: -60, minSamples: 3, isPresent: false) == true,
      "smoothed -55 with 3 samples -> unlock")
check(shouldUnlock(estimatedRSSI: -55, sampleCount: 2, unlockThreshold: -60, minSamples: 3, isPresent: false) == false,
      "strong signal but only 2 samples -> no unlock (warm-up)")
check(shouldUnlock(estimatedRSSI: -55, sampleCount: 5, unlockThreshold: -60, minSamples: 3, isPresent: true) == false,
      "already present -> never re-unlock")
check(shouldUnlock(estimatedRSSI: -60, sampleCount: 3, unlockThreshold: -60, minSamples: 3, isPresent: false) == true,
      "exactly at threshold -> unlock")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }
