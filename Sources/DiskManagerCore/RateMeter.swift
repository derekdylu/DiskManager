import Foundation

/// Measures throughput over a sliding window (last 10 s) so the rate reacts to speed changes,
/// falling back to the overall average until enough samples exist.
public struct RateMeter: Sendable {
    private let window: TimeInterval = 10
    private var samples: [(time: Date, value: Int64)] = []
    private var startTime: Date?
    private var startValue: Int64 = 0

    public init() {}

    public mutating func reset(_ value: Int64 = 0, at time: Date = Date()) {
        samples = [(time, value)]
        startTime = time
        startValue = value
    }

    /// Records a new cumulative value and returns the current rate per second
    public mutating func record(_ value: Int64, at time: Date = Date()) -> Double {
        if startTime == nil { reset(value, at: time); return 0 }
        samples.append((time, value))
        let cutoff = time.addingTimeInterval(-window)
        samples.removeAll { $0.time < cutoff }
        if let first = samples.first, time.timeIntervalSince(first.time) >= 1 {
            return Double(value - first.value) / time.timeIntervalSince(first.time)
        }
        if let startTime, time.timeIntervalSince(startTime) >= 1 {
            return Double(value - startValue) / time.timeIntervalSince(startTime)
        }
        return 0
    }
}
