import Foundation
import Testing
@testable import ClientCore

/// The real timer of the watchdog, started from the main actor as main.swift
/// starts it. In 2.3.0 the handler was written in main.swift, inherited the
/// main actor and stopped the daemon the first time it fired on its queue
/// (EXC_BREAKPOINT in dispatch_assert_queue_fail); this test crashed with it.
private final class Fired: @unchecked Sendable {
    let lock = NSLock(); var count = 0, onMain = false
    func add() { lock.lock(); count += 1; onMain = Thread.isMainThread; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor @Test func watchdogTimerFiresOnItsOwnQueueWhenStartedFromTheMainActor() async throws {
    let fired = Fired()
    let watchdog = TickWatchdog(limit: 0.1) { _ in fired.add() }
    watchdog.watch(every: 0.05)
    // A step that never ends.
    watchdog.begin(Date())
    for _ in 0..<40 where fired.value == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
    watchdog.stop()
    #expect(fired.value == 1 && !fired.onMain, "the stall is seen once, on the watchdog's queue")
    // Steps that end in time are never taken for stalled.
    let quiet = Fired()
    let healthy = TickWatchdog(limit: 0.3) { _ in quiet.add() }
    healthy.watch(every: 0.05)
    for _ in 0..<8 { healthy.begin(); try await Task.sleep(nanoseconds: 50_000_000); healthy.end() }
    healthy.stop()
    #expect(quiet.value == 0)
}
