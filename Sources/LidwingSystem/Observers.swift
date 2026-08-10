import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import CoreGraphics
import LidwingCore

/// Everything the machine can tell us, delivered as one enum on the main queue.
public enum SystemSignal: Equatable, Sendable {
    case clamshell(closed: Bool?, causesSleep: Bool?)
    case canSystemSleep(argument: UInt)
    case systemWillSleep(argument: UInt)
    case systemHasPoweredOn
    case powerSourceChanged
    case displayReconfigured
    case thermalChanged
}

/// Concurrency contract, pinned here because Swift 6 emits **zero** diagnostics when an
/// imported `@convention(c)` IOKit callback captures actor-isolated state through
/// `Unmanaged.fromOpaque`:
///
/// **A C callback in this file does nothing but decode its argument and hop to the main queue.**
/// No state is read or written inside one. Every observer below obeys that rule, and any new
/// one must too.
public final class SystemObservers {

    public typealias Handler = (SystemSignal) -> Void

    private let handler: Handler

    // Clamshell interest notification. Its own port: `IORegisterForSystemPower` delivers only
    // the sleep/wake messages and never the clamshell ones, so two registrations are mandatory.
    private var interestPort: IONotificationPortRef?
    private var interestNotifier: io_object_t = 0

    // System power notifications.
    private var rootPort: io_connect_t = 0
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0

    private var powerSourceSource: CFRunLoopSource?
    private var displayCallbackInstalled = false
    private var thermalToken: NSObjectProtocol?

    /// Last known lid state, so we can diff rather than count.
    ///
    /// `kIOPMMessageClamshellStateChange` fires on four non-lid triggers —
    /// `kIOPMSetDesktopMode`, `kIOPMSetACAdaptorConnected`, `kIOPMEnableClamshell`,
    /// `kIOPMDisableClamshell` — and arrives twice per transition. Counting instead of diffing
    /// produces a fake "lid closed" on every charger plug.
    private var lastClamshellClosed: Bool?
    public private(set) var sawClamshellNotification = false

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    private func emit(_ signal: SystemSignal) {
        let handler = self.handler
        DispatchQueue.main.async { handler(signal) }
    }

    // MARK: start / stop

    public func start() {
        startClamshellInterest()
        startSystemPower()
        startPowerSource()
        startDisplayReconfiguration()
        startThermal()
    }

    public func stop() {
        if interestNotifier != 0 { IOObjectRelease(interestNotifier); interestNotifier = 0 }
        if let port = interestPort {
            let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            IONotificationPortDestroy(port)
            interestPort = nil
        }
        if powerNotifier != 0 {
            IODeregisterForSystemPower(&powerNotifier)
            powerNotifier = 0
        }
        if let port = powerPort {
            let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            IONotificationPortDestroy(port)
            powerPort = nil
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
        if let source = powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceSource = nil
        }
        if displayCallbackInstalled {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback,
                                                   Unmanaged.passUnretained(self).toOpaque())
            displayCallbackInstalled = false
        }
        if let token = thermalToken {
            NotificationCenter.default.removeObserver(token)
            thermalToken = nil
        }
    }

    // MARK: clamshell

    private func startClamshellInterest() {
        let service = RootDomain.matchingService()
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        guard let port = IONotificationPortCreate(RootDomain.mainPort) else { return }
        interestPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, service, kIOGeneralInterest,
                                         clamshellInterestCallback, context, &interestNotifier)
    }

    fileprivate func handleClamshellMessage(_ messageType: UInt32, argument: UInt) {
        guard messageType == PMMsg.clamshellStateChange else { return }
        sawClamshellNotification = true
        let closed = (UInt32(argument & 0xFFFF_FFFF) & PMMsg.clamshellStateBit) != 0
        let causesSleep = (UInt32(argument & 0xFFFF_FFFF) & PMMsg.clamshellSleepBit) != 0
        defer { lastClamshellClosed = closed }
        emit(.clamshell(closed: closed, causesSleep: causesSleep))
    }

    // MARK: system power

    private func startSystemPower() {
        var notifier: io_object_t = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        let connection = IORegisterForSystemPower(context, &powerPort,
                                                  systemPowerCallback, &notifier)
        guard connection != 0, let port = powerPort else { return }
        rootPort = connection
        powerNotifier = notifier
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
    }

    fileprivate func handleSystemPower(_ messageType: UInt32, argument: UInt) {
        switch messageType {
        case PMMsg.canSystemSleep:
            emit(.canSystemSleep(argument: argument))
        case PMMsg.systemWillSleep:
            emit(.systemWillSleep(argument: argument))
        case PMMsg.systemHasPoweredOn:
            emit(.systemHasPoweredOn)
        default:
            break
        }
    }

    /// Acknowledge a power change. Never a veto: `IOCancelPowerChange` cannot stop a demand
    /// sleep, and failing to acknowledge stalls the entire system's sleep transition for about
    /// thirty seconds, which becomes "my Mac takes half a minute to sleep" and is blamed on us.
    public func allowPowerChange(_ argument: UInt) {
        guard rootPort != 0 else { return }
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    }

    // MARK: power source

    private func startPowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceCallback, context)?
                .takeRetainedValue() else { return }
        powerSourceSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    fileprivate func handlePowerSourceChange() {
        emit(.powerSourceChanged)
    }

    // MARK: displays

    private func startDisplayReconfiguration() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
            == .success {
            displayCallbackInstalled = true
        }
    }

    fileprivate func handleDisplayReconfiguration() {
        emit(.displayReconfigured)
    }

    // MARK: thermal

    private func startThermal() {
        thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.emit(.thermalChanged)
            }
    }

    /// Number of online displays.
    ///
    /// `CGGetOnlineDisplayList` is the right call. Never `IODisplayWrangler`: the node exists on
    /// Apple silicon but carries no `IOPowerManagement` dictionary, so there is no power state
    /// to read. And "zero displays" is a different state from "display asleep" —
    /// `CGDisplayIsAsleep(CGMainDisplayID())` is undefined when `CGMainDisplayID()` returns
    /// `kCGNullDirectDisplay`, which is exactly the state this product creates.
    public static func onlineDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return 1 }
        return Int(count)
    }
}

// MARK: - C callbacks
//
// Each one decodes its argument and hops to the main queue. Nothing else. See the concurrency
// contract at the top of this file.

private func clamshellInterestCallback(refcon: UnsafeMutableRawPointer?,
                                       service: io_service_t,
                                       messageType: UInt32,
                                       messageArgument: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let observers = Unmanaged<SystemObservers>.fromOpaque(refcon).takeUnretainedValue()
    observers.handleClamshellMessage(messageType, argument: UInt(bitPattern: messageArgument))
}

private func systemPowerCallback(refcon: UnsafeMutableRawPointer?,
                                 service: io_service_t,
                                 messageType: UInt32,
                                 messageArgument: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let observers = Unmanaged<SystemObservers>.fromOpaque(refcon).takeUnretainedValue()
    observers.handleSystemPower(messageType, argument: UInt(bitPattern: messageArgument))
}

private func powerSourceCallback(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let observers = Unmanaged<SystemObservers>.fromOpaque(context).takeUnretainedValue()
    observers.handlePowerSourceChange()
}

private func displayReconfigurationCallback(display: CGDirectDisplayID,
                                            flags: CGDisplayChangeSummaryFlags,
                                            userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let observers = Unmanaged<SystemObservers>.fromOpaque(userInfo).takeUnretainedValue()
    observers.handleDisplayReconfiguration()
}
