import ClientCore
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Sleep and wake. Before sleep the permission goes and the denial stays;
/// after wake the daemon takes a step at once instead of waiting out a retry.
final class PowerWatch: @unchecked Sendable {
    // iokit_common_msg(...): sys_iokit | sub_iokit_common | message.
    static let canSleep: UInt32 = 0xE000_0270, willSleep: UInt32 = 0xE000_0280, poweredOn: UInt32 = 0xE000_0300
    private let runtime: ClientRuntime
    private var root: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private let queue = DispatchQueue(label: "power")

    init(runtime: ClientRuntime) {
        self.runtime = runtime
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            Unmanaged<PowerWatch>.fromOpaque(context).takeUnretainedValue().handle(message, argument)
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, queue) }
    }

    private func handle(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch message {
        case Self.canSleep:
            IOAllowPowerChange(root, token)
        case Self.willSleep:
            // Permission is withdrawn before the system goes; a few seconds at most.
            let done = DispatchSemaphore(value: 0)
            Task.detached { [runtime] in await runtime.willSleep(); done.signal() }
            _ = done.wait(timeout: .now() + 5)
            IOAllowPowerChange(root, token)
        case Self.poweredOn:
            Task.detached { [runtime] in await runtime.didWake(); await runtime.tick() }
        default:
            break
        }
    }
}
