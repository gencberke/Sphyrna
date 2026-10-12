import Foundation

/// Counts differing bytes of two equally sized pixel buffers. The tests run in
/// debug builds on the MainActor, where `zip(...).reduce` over a 2 MB bitmap
/// costs about 0.25 s per call and, repeated per step, held the MainActor for
/// seconds and starved other suites' main-actor work (the launch hop of
/// `TerminalRunControllerTests`). Equal buffers take a `memcmp` fast path; a
/// mismatch is counted over raw buffers.
func differingBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
    guard a.count == b.count else { return max(a.count, b.count) }
    return a.withUnsafeBufferPointer { left in
        b.withUnsafeBufferPointer { right in
            guard let leftBase = left.baseAddress, let rightBase = right.baseAddress else { return 0 }
            if memcmp(leftBase, rightBase, left.count) == 0 { return 0 }
            var count = 0
            for index in 0..<left.count where leftBase[index] != rightBase[index] { count += 1 }
            return count
        }
    }
}
