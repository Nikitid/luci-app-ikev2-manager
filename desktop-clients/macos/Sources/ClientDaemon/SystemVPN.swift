import Foundation

/// The system's VPN configuration that the profile installed, found by its
/// name, and its session: whether it is connected, and starting and stopping
/// it. `scutil --nc` neither lists nor drives an IKEv2 configuration, so this
/// goes to the same interface the system's own VPN menu uses. It is not a
/// published one; every symbol is looked up when needed, and without them the
/// client reports that there is no profile instead of failing.
final class SystemVPN: @unchecked Sendable {
    private typealias Create = @convention(c) (UnsafePointer<UInt8>, Int32) -> OpaquePointer?
    private typealias Act = @convention(c) (OpaquePointer) -> Void
    private typealias Status = @convention(c) (OpaquePointer, DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias Load = @convention(c) (AnyObject, Selector, DispatchQueue, @escaping @convention(block) (NSArray?, NSError?) -> Void) -> Void

    private let name: String
    private let lock = NSLock()
    private var identifier: UUID?
    private var checkedUntil = Date.distantPast
    private var session: OpaquePointer?
    private let library = dlopen(nil, RTLD_NOW)

    init(name: String) {
        self.name = name
        _ = dlopen("/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension", RTLD_NOW)
    }

    private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Asks the system for its configurations; at most every five seconds.
    private func find() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        if Date() < checkedUntil { return identifier }
        checkedUntil = Date().addingTimeInterval(5)
        var found: UUID?
        let selector = NSSelectorFromString("loadConfigurationsWithCompletionQueue:handler:")
        if let manager = (NSClassFromString("NEConfigurationManager") as? NSObject.Type)?
            .perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject,
           manager.responds(to: selector), let method = class_getMethodImplementation(type(of: manager), selector) {
            let done = DispatchSemaphore(value: 0), wanted = name
            unsafeBitCast(method, to: Load.self)(manager, selector, DispatchQueue.global()) { list, _ in
                for item in list ?? [] {
                    guard let object = item as? NSObject, object.value(forKey: "name") as? String == wanted else { continue }
                    found = object.value(forKey: "identifier") as? UUID
                }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
        }
        if found != identifier { session = nil }
        identifier = found
        return found
    }

    private func open() -> OpaquePointer? {
        guard let identifier = find() else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let session { return session }
        guard let create = symbol("ne_session_create", Create.self) else { return nil }
        var raw = identifier.uuid
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        session = bytes.withUnsafeBufferPointer { create($0.baseAddress!, 1) }
        return session
    }

    var installed: Bool { find() != nil }

    var connected: Bool {
        guard let session = open(), let status = symbol("ne_session_get_status", Status.self) else { return false }
        let done = DispatchSemaphore(value: 0)
        var value: Int32 = 0
        status(session, DispatchQueue.global()) { value = $0; done.signal() }
        _ = done.wait(timeout: .now() + 3)
        return value == 3
    }

    func start() throws {
        guard let session = open(), let start = symbol("ne_session_start", Act.self) else { throw CocoaError(.featureUnsupported) }
        start(session)
    }

    func stop() throws {
        guard let session = open(), let stop = symbol("ne_session_stop", Act.self) else { throw CocoaError(.featureUnsupported) }
        stop(session)
    }
}
