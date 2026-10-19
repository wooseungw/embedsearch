import Foundation
import IOKit.ps

/// Whether the Mac runs on external power, so work done ahead of need costs no battery.
enum PowerSource {
    /// On an unlimited source (a power adapter, or a UPS while mains is up; always on a Mac
    /// without a battery or UPS) and not in Low Power Mode, which can be on with the adapter too.
    /// False on a battery, including a UPS's.
    static var allowsWorkAhead: Bool {
        !ProcessInfo.processInfo.isLowPowerModeEnabled && IOPSGetTimeRemainingEstimate() == kIOPSTimeRemainingUnlimited
    }
}
