import Foundation
import IOKit.pwr_mgt

/// Holds IOKit power assertions while at least one engine is resident,
/// preventing Mac + disk idle sleep (PROTOCOL §6). Released when idle/paused.
public final class SleepGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var systemId: IOPMAssertionID = 0
    private var diskId: IOPMAssertionID = 0
    private var active = false

    public init() {}

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }; return active
    }

    public func setActive(_ on: Bool, reason: String = "Substation engine resident") {
        lock.lock(); defer { lock.unlock() }
        if on, !active {
            var sid: IOPMAssertionID = 0
            let kr1 = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &sid)
            if kr1 == kIOReturnSuccess { systemId = sid }
            var did: IOPMAssertionID = 0
            let kr2 = IOPMAssertionCreateWithName(
                "PreventDiskIdle" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &did)
            if kr2 == kIOReturnSuccess { diskId = did }
            active = kr1 == kIOReturnSuccess || kr2 == kIOReturnSuccess
        } else if !on, active {
            if systemId != 0 { IOPMAssertionRelease(systemId); systemId = 0 }
            if diskId != 0 { IOPMAssertionRelease(diskId); diskId = 0 }
            active = false
        }
    }
}
