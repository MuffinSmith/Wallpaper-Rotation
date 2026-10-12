import Foundation

/// Persisted attempt reservations prevent restart and immediate successful-purge loops.
/// Only an hour of mapped-scene readiness resets the attempt ladder.
struct AutomaticRecoveryPolicy: Codable, Equatable {
    private(set) var attemptCount = 0
    private(set) var lastActivityAt: Date?
    private(set) var nextEligibleAt: Date?
    private(set) var healthySince: Date?

    private var delay: TimeInterval {
        switch attemptCount {
        case ...1: 5 * 60
        case 2: 15 * 60
        default: 60 * 60
        }
    }
    mutating func beginAttempt(at date: Date) {
        healthySince = nil
        attemptCount = min(3, attemptCount + 1)
        lastActivityAt = date
        nextEligibleAt = date.addingTimeInterval(delay)
    }
    mutating func noteMissing(at date: Date) {
        if let healthySince, date.timeIntervalSince(healthySince) >= 60 * 60 { attemptCount = 0 }
        // Clear as soon as missing assets are observed, before any waiting period.
        // Time spent in backoff must never count toward a healthy quiet interval.
        healthySince = nil
    }
    mutating func markReady(at date: Date) {
        if healthySince == nil { healthySince = date }
    }
    mutating func finishAttempt(at date: Date) {
        lastActivityAt = date
        nextEligibleAt = date.addingTimeInterval(delay)
    }
}
