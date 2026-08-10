import Foundation

/// IOKit power-management message constants.
///
/// None of these are importable into Swift: the ClangImporter reports "macro unavailable:
/// structure not supported" because they expand through `iokit_family_msg()`. The values below
/// were recomputed from the real SDK headers.
///
/// The one that bites: `kIOPMMessageClamshellStateChange` is
/// `iokit_family_msg(sub_iokit_powermanagement = 13, 0x100)` = `0xE0034100`. The value
/// `0xE0024100` is widely copied on the internet and is **wrong** — it uses sub-family 9. With
/// it the callback silently never matches, and the feature "just doesn't work" with no error
/// anywhere.
public enum PMMsg {
    public static let canSystemSleep: UInt32 = 0xE000_0270
    public static let systemWillSleep: UInt32 = 0xE000_0280
    public static let systemWillNotSleep: UInt32 = 0xE000_0290
    public static let systemHasPoweredOn: UInt32 = 0xE000_0300
    public static let systemWillPowerOn: UInt32 = 0xE000_0320
    public static let systemCapabilityChange: UInt32 = 0xE000_0340
    public static let clamshellStateChange: UInt32 = 0xE003_4100
    public static let driverAssertionsChanged: UInt32 = 0xE003_4150

    /// `IOPM.h:425` — 1 means the lid is CLOSED.
    public static let clamshellStateBit: UInt32 = 1 << 0
    /// `IOPM.h:426` — 1 means the clamshell currently causes sleep.
    public static let clamshellSleepBit: UInt32 = 1 << 1
}

/// `IOKit/pwr_mgt/IOPMLibDefs.h:42` — `#define kPMSetClamshellSleepState 12`.
///
/// Its dispatch entry in `RootDomainUserClient` has `.checkEntitlement = NULL` and makes no
/// `clientHasPrivilege()` call, unlike selectors 13 and 15 which do. That is why this works as
/// an ordinary user, and it is the single fact the whole product rests on.
public let kPMSetClamshellSleepStateSelector: UInt32 = 12
