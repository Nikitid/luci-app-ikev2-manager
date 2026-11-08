import Foundation

/// One step of a reset, in the order they are taken.
public enum ResetStep: String, CaseIterable, Codable, Sendable {
    case connection = "vpn_connection", profile = "vpn_profile", browsers = "browser_profile"
    case hosts, names, filter = "packet_filter", registration
}

/// What a reset did, step by step, as read back from the system afterwards.
public struct ResetReport: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case removed, absent, failed }
    public struct Entry: Codable, Sendable, Equatable {
        public var step: ResetStep
        public var outcome: Outcome
        /// Why a step failed: "refused" (the system said no) or "still_present" (it read back).
        public var reason: String?
        public init(step: ResetStep, outcome: Outcome, reason: String? = nil) { self.step = step; self.outcome = outcome; self.reason = reason }
    }
    public var steps: [Entry]
    public var complete: Bool { !steps.contains { $0.outcome == .failed } }
    public var failed: [ResetStep] { steps.filter { $0.outcome == .failed }.map(\.step) }
    public init(steps: [Entry]) { self.steps = steps }
}

/// Left in the daemon's directory while a reset has steps still to do; the
/// daemon takes them again on every step and at start until none is left.
public struct ResetMark: Codable, Sendable, Equatable {
    public var version = 1
    public var startedAt: Int
    public var pending: [ResetStep]
    /// The VPN profile to remove, kept here because the registration that named it is gone.
    public var profile: String?
    public init(startedAt: Int, pending: [ResetStep], profile: String?) { self.startedAt = startedAt; self.pending = pending; self.profile = profile }
}

/// A failure of the daemon itself, kept as a code and a time and nothing else.
public struct FaultEvent: Codable, Sendable, Equatable {
    public static let limit = 40
    public var code: String
    public var phase: String
    public var at: Int
    public init(code: String, phase: String, at: Int) { self.code = code; self.phase = phase; self.at = at }
}

/// Watches the daemon's step from outside it. A step that has not finished
/// within the limit is taken for stalled: the daemon records it and exits,
/// and launchd starts it again. Checked from its own queue, so a step that
/// holds the runtime cannot hold the watchdog too.
public final class TickWatchdog: @unchecked Sendable {
    public static let limit: TimeInterval = 60
    private let lock = NSLock()
    private var startedAt: Date?
    private var fired = false
    private let limit: TimeInterval
    private let onStall: @Sendable (TimeInterval) -> Void

    public init(limit: TimeInterval = TickWatchdog.limit, onStall: @escaping @Sendable (TimeInterval) -> Void) {
        self.limit = limit; self.onStall = onStall
    }

    public func begin(_ now: Date = Date()) { lock.lock(); startedAt = now; lock.unlock() }
    public func end() { lock.lock(); startedAt = nil; lock.unlock() }

    /// Whether the step in progress is stalled; the first time it is, says so once.
    @discardableResult public func check(_ now: Date = Date()) -> Bool {
        lock.lock()
        guard let startedAt, !fired, now.timeIntervalSince(startedAt) > limit else { lock.unlock(); return false }
        fired = true
        lock.unlock()
        onStall(now.timeIntervalSince(startedAt))
        return true
    }
}
