import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Thin wrappers over the IOKit calls the app needs. No state lives here.
enum SystemPower {
    struct Battery: Equatable {
        /// Charge in percent, or nil when the Mac has no internal battery.
        var percent: Int?
        /// True on AC power. A Mac without a battery counts as always on AC.
        var onAC: Bool
    }

    // MARK: Lid

    /// Reads `AppleClamshellState` from `IOPMrootDomain`.
    /// A missing property (desktop Mac) is treated as "open".
    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(), CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return false
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    // MARK: Battery

    static func readBattery() -> Battery {
        let noBattery = Battery(percent: nil, onAC: true)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return noBattery }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            var percent: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int {
                let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
                percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : nil
            }
            return Battery(percent: percent, onAC: onAC)
        }
        return noBattery
    }

    // MARK: Assertions

    /// Takes an IOPM power assertion, the same mechanism `caffeinate` uses.
    static func createAssertion(type: CFString, reason: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id
        )
        return result == kIOReturnSuccess ? id : nil
    }

    static func releaseAssertion(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}
