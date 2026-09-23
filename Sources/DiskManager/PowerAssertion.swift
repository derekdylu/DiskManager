import Foundation
import IOKit.pwr_mgt

/// Prevents system or display sleep via an IOKit power assertion
final class PowerAssertion {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func activate(reason: String, keepDisplayOn: Bool) {
        guard !isActive else { return }
        let type = keepDisplayOn
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        let status = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID)
        isActive = (status == kIOReturnSuccess)
    }

    func release() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        isActive = false
    }

    deinit { release() }
}
