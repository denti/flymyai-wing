import Foundation
import IOKit
import IOKit.ps
import LidwingCore

/// Battery and power-source reads.
///
/// Never `pmset -g batt`: it silently loses a time estimate the API has, and it costs a
/// process spawn per sample on a loop that runs every five seconds.
public enum PowerSourceReader {

    public struct Reading {
        public let onAC: Bool
        /// Raw capacity units, exactly as reported. The percentage is computed by
        /// `LidwingCore.PowerSample`, deliberately: treating `CurrentCapacity` as a percentage
        /// is the bug that makes a battery guard silently never fire.
        public let current: Int?
        public let max: Int?
        public let warning: BatteryWarning
        public let hasInternalBattery: Bool
    }

    public static func read() -> Reading {
        let warning = warningLevel()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            // No power-source information at all. A desktop, or a very early boot. Treat it as
            // AC so the battery guard cannot fire on a machine with no battery.
            return Reading(onAC: true, current: nil, max: nil, warning: warning,
                           hasInternalBattery: false)
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            guard (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let state = info[kIOPSPowerSourceStateKey] as? String
            return Reading(onAC: state == kIOPSACPowerValue,
                           current: info[kIOPSCurrentCapacityKey] as? Int,
                           max: info[kIOPSMaxCapacityKey] as? Int,
                           warning: warning,
                           hasInternalBattery: true)
        }
        return Reading(onAC: true, current: nil, max: nil, warning: warning,
                       hasInternalBattery: false)
    }

    /// `IOPSGetBatteryWarningLevel`. `kIOPSLowBatteryWarningFinal` is 3.
    public static func warningLevel() -> BatteryWarning {
        switch IOPSGetBatteryWarningLevel() {
        case kIOPSLowBatteryWarningFinal: return .final
        case kIOPSLowBatteryWarningEarly: return .early
        default: return .none
        }
    }

    /// Live watts on battery, from `AppleSmartBattery`.
    ///
    /// Read through the property API, never by parsing `ioreg` text: `ioreg` prints
    /// `18446744073709550889` for a negative current, and multiplying that by the voltage
    /// yields about 2.3e17 watts, which is the kind of number that ends up in a screenshot.
    public static func instantaneousWatts() -> Double? {
        let service = IOServiceGetMatchingService(RootDomain.mainPort,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

        // InstantAmperage is signed: negative while discharging.
        guard let milliAmps = (properties["InstantAmperage"] as? NSNumber)?.int64Value,
              let milliVolts = (properties["Voltage"] as? NSNumber)?.int64Value else { return nil }
        let watts = abs(Double(milliAmps) * Double(milliVolts)) / 1_000_000.0
        // A laptop that claims to be drawing more than a kilowatt is reporting garbage, not
        // news. Refuse the number rather than display it.
        guard watts.isFinite, watts < 1000 else { return nil }
        return watts
    }
}
