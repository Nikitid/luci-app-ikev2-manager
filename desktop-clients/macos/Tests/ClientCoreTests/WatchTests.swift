import Foundation
import Testing
@testable import ClientCore

/// The window hears of a change at once, not on its next poll.
@Test func aChangeWakesTheWindowAtOnce() async throws {
    var (runtime, _, _, store, now) = try await registered()
    // The server's address is looked up in the background and lands once.
    for _ in 0..<2 { await runtime.tick(now: now); now += 2 }
    let seen = await runtime.sequence
    // Nothing changes: the question is held to its timeout.
    let started = Date()
    let quiet = await runtime.waitForChange(after: seen, timeout: 0.3)
    #expect(quiet.sequence == seen && Date().timeIntervalSince(started) >= 0.25)
    // A step that changes nothing but the time is no change either.
    await runtime.tick(now: now); now += 2
    #expect(await runtime.sequence == seen)
    // Switching on: the waiting question is answered as soon as the step publishes.
    let waiting = Task { await runtime.waitForChange(after: seen, timeout: 10) }
    try await Task.sleep(nanoseconds: 50_000_000)
    let asked = Date()
    try await runtime.setWanted(true)
    await runtime.tick(now: now)
    let answer = await waiting.value
    #expect(answer.sequence > seen && answer.status.state == "connecting")
    #expect(Date().timeIntervalSince(asked) < 1, "answered at once, not after the timeout")
    // A window that missed changes gets the current status without waiting.
    let behind = await runtime.waitForChange(after: seen, timeout: 10)
    #expect(behind.sequence == answer.sequence)
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func theWindowDoesNotBlinkWhileTheDaemonRestarts() {
    var link = DaemonLink()
    link.missed()
    #expect(!link.failed, "one missed answer is a restart, not a loss")
    link.missed()
    #expect(link.failed)
    link.answered()
    #expect(!link.failed)

    func status(_ state: String) -> ClientStatusReport {
        ClientStatusReport(state: state, guardInstalled: true, protected: false, routed: false, wanted: false, profileInstalled: false,
                           error: "none", services: [], available: [], domains: 0, revision: 1, release: "", updatedAt: 0)
    }
    var gate = FirstRunGate()
    let before = gate.update(status: nil, done: false)
    #expect(!before, "nothing is decided before the first answer")
    let first = gate.update(status: status("profile_required"), done: false)
    #expect(first)
    let gone = gate.update(status: nil, done: false)
    #expect(gone, "the daemon going away keeps the page")
    let passing = gate.update(status: status("enrollment_required"), done: false)
    #expect(passing, "and so does a passing state")
    let finished = gate.update(status: status("blocked"), done: true)
    #expect(!finished)
    var fresh = FirstRunGate()
    let unregistered = fresh.update(status: status("enrollment_required"), done: false)
    #expect(!unregistered)
}
