import Foundation
import Testing
@testable import ClientCore

/// The daemon mends what it can by itself and never forgets the device on its own.

private func protectedDevice() async throws -> (ClientRuntime, Machine, Router, ClientStore, Date) {
    var (runtime, machine, router, store, now) = try await registered()
    try await runtime.setWanted(true)
    machine.sync { machine.connected = true; machine.tunnel = TunnelObservation(interface: "ipsec0", address: "10.20.0.7") }
    router.sync { router.ready = .success(DeviceReadiness(id: "alice-mac", address: "10.20.0.7", revision: 1)) }
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().protected)
    return (runtime, machine, router, store, now)
}

@Test func resetGoesOnPastAFailedStepAndFinishesLater() async throws {
    let (runtime, machine, router, store, now) = try await protectedDevice()
    machine.sync { machine.hostsBroken = true }
    _ = try? await runtime.reset(now: now)
    #expect(machine.rules.isEmpty, "the anchor is emptied although the hosts file could not be written")
    #expect(machine.resolving.isEmpty && !machine.installed)
    #expect(try store.loadRegistration() == nil, "the registration goes all the same")
    #expect(machine.hosts.contains("api.example.com"))
    // What is left is done again by the next step, also after a restart, and
    // a new registration waits until it is.
    await #expect(throws: (any Error).self) { try await runtime.begin(invitation: invitation) }
    let restarted = ClientRuntime(store: store, system: machine, transport: router)
    await restarted.tick(now: now + 2)
    #expect(machine.hosts.contains("api.example.com"), "the hosts file still refuses")
    machine.sync { machine.hostsBroken = false }
    await restarted.tick(now: now + 4)
    #expect(!machine.hosts.contains("api.example.com") && machine.hosts.contains("localhost"))
    #expect(await restarted.status().state == "enrollment_required")
    router.sync { router.claimed = false; router.enrolled = false }
    try await restarted.begin(invitation: invitation)
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func filterSwitchedOffIsSwitchedOnAgainWhileServicesStayClosed() async throws {
    var (runtime, machine, _, store, now) = try await protectedDevice()
    machine.sync { machine.effective = false; machine.restorable = true; machine.log.removeAll() }
    await runtime.tick(now: now); now += 2
    #expect(machine.restored == 1)
    let restore = try #require(machine.log.firstIndex(of: "restore"))
    #expect(machine.sync { machine.log.count > restore }, "permission comes back only after the filter acts again")
    #expect(await runtime.status().state == "protected")
    // A filter that will not come back: five tries, then the guard is reported unconfirmed.
    machine.sync { machine.effective = false; machine.restorable = false }
    for _ in 0..<4 { await runtime.tick(now: now); now += 2 }
    var status = await runtime.status()
    #expect(status.state == "error" && status.error == "guard_restoring" && !machine.rules.contains("pass"))
    await runtime.tick(now: now); now += 2
    status = await runtime.status()
    #expect(status.state == "error" && status.error == "guard_unconfirmed" && !status.protected)
    machine.sync { machine.restorable = true }
    await runtime.tick(now: now); now += 2
    #expect(await runtime.status().state == "protected")
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func profileTheOwnerRemovedIsNamedSo() async throws {
    var (runtime, machine, _, store, now) = try await protectedDevice()
    machine.sync { machine.installed = false }
    await runtime.tick(now: now); now += 2
    let status = await runtime.status()
    #expect(status.state == "profile_required" && status.error == "profile_removed" && !machine.rules.contains("pass"))
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func damagedRegistrationWaitsForTheOwnerAndIsKept() async throws {
    var (runtime, machine, _, store, now) = try await protectedDevice()
    let file = store.directory.appendingPathComponent("enrollment.json")
    try Data("{ broken".utf8).write(to: file)
    chmod(file.path, 0o600)
    await runtime.tick(now: now); now += 2
    let status = await runtime.status()
    #expect(status.state == "needs_reset" && !status.protected && !machine.rules.contains("pass"))
    #expect(machine.rules.contains("block drop"), "the denial stays")
    #expect(FileManager.default.fileExists(atPath: file.path), "nothing is reset by itself: the link was single-use")
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func resetNamesEveryStepAndASecondOneFindsNothing() async throws {
    let (runtime, machine, _, store, now) = try await protectedDevice()
    machine.sync { machine.browserProfile = true }
    let first = await runtime.reset(now: now)
    #expect(first.steps.first { $0.step == .browsers }?.outcome == .removed && !machine.browserProfile)
    #expect(first.complete && first.steps.map(\.step) == ResetStep.allCases)
    #expect(first.steps.first { $0.step == .connection }?.outcome == .removed)
    #expect(first.steps.first { $0.step == .profile }?.outcome == .removed)
    #expect(first.steps.first { $0.step == .filter }?.outcome == .removed)
    #expect(first.steps.first { $0.step == .registration }?.outcome == .removed)
    #expect(try store.loadResetMark() == nil, "a finished reset leaves no mark")
    let second = await runtime.reset(now: now + 1)
    #expect(second.complete && second.steps.allSatisfy { $0.outcome == .absent }, "\(second.steps)")
    #expect(machine.rules.isEmpty && machine.resolving.isEmpty)
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func resetThatFailsSaysWhichStepAndWhy() async throws {
    let (runtime, machine, _, store, now) = try await protectedDevice()
    machine.sync { machine.hostsBroken = true }
    let done = await runtime.reset(now: now)
    #expect(!done.complete && done.failed == [.hosts])
    #expect(done.steps.first { $0.step == .hosts }?.reason == "refused")
    #expect(try store.loadResetMark()?.pending == [.hosts])
    let status = await runtime.status()
    #expect(status.state == "reset_incomplete" && status.reset?.failed == [.hosts])
    // A reset still unfinished ten minutes on is a failure of the program.
    await runtime.tick(now: now + 601)
    #expect(store.loadFaults().contains { $0.code == "reset_incomplete" && $0.phase == "reset" })
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func uninstallLeavesNothingOfTheDaemon() async throws {
    let (runtime, machine, _, store, _) = try await protectedDevice()
    let done = try await runtime.remove()
    #expect(done.complete && machine.rules.isEmpty && !FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func watchdogFiresOnceForAStalledStep() {
    final class Count: @unchecked Sendable { let lock = NSLock(); var value = 0 }
    let fired = Count()
    let watchdog = TickWatchdog(limit: 60) { _ in fired.lock.lock(); fired.value += 1; fired.lock.unlock() }
    let start = Date(timeIntervalSince1970: 0)
    #expect(!watchdog.check(start + 100), "no step, nothing stalled")
    watchdog.begin(start)
    #expect(!watchdog.check(start + 59))
    watchdog.end()
    #expect(!watchdog.check(start + 120), "a finished step is not stalled")
    watchdog.begin(start + 200)
    #expect(watchdog.check(start + 261))
    #expect(!watchdog.check(start + 300), "said once")
    #expect(fired.value == 1)
}

@Test func sleepClosesAndWakeConnectsAtOnce() async throws {
    var (runtime, machine, _, store, now) = try await protectedDevice()
    await runtime.willSleep()
    #expect(!machine.rules.contains("pass") && machine.rules.contains("block drop"), "permission goes before sleep, the denial stays")
    await runtime.tick(now: now); now += 2
    #expect(!machine.rules.contains("pass"), "nothing opens between going to sleep and sleep")
    // The tunnel dropped while asleep and a retry was due only later.
    machine.sync { machine.connected = false }
    await runtime.didWake()
    await runtime.tick(now: now); now += 1
    let started = machine.started
    machine.sync { machine.connected = false }
    await runtime.willSleep(); await runtime.didWake()
    await runtime.tick(now: now)
    #expect(machine.started == started + 1, "after wake the connection is asked for at once, not after the retry pause")
    try? FileManager.default.removeItem(at: store.directory)
}

@Test func failuresAreKeptAsCodesOnceInTenMinutes() async throws {
    var (runtime, machine, _, store, now) = try await protectedDevice()
    machine.sync { machine.effective = false }
    for _ in 0..<8 { await runtime.tick(now: now); now += 2 }
    let kept = store.loadFaults().filter { $0.code == "guard_unconfirmed" }
    #expect(kept.count == 1 && kept[0].phase == "pf")
    let text = String(decoding: try JSONEncoder().encode(store.loadFaults()), as: UTF8.self)
    #expect(!text.contains("example.com") && !text.contains("10.20.0.7"), "codes and times only")
    try? FileManager.default.removeItem(at: store.directory)
}
