import Foundation
import IOKit.pwr_mgt

/// Settings → General → Keep Mac awake. Off (the default) leaves sleep to macOS; While a session works holds off idle system
/// sleep, never display sleep, for as long as any session works.
public enum KeepAwakeSetting: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case whileWorking

    /// The label in Settings.
    public var title: String {
        switch self {
        case .off: "Off"
        case .whileWorking: "While a session works"
        }
    }
}

/// One power assertion against idle system sleep. The live one is IOKit's; a test records the calls instead.
@MainActor
public protocol IdleSleepAssertion: AnyObject {
    /// Takes the assertion; false when the system refused it.
    func hold() -> Bool
    func release()
}

/// `kIOPMAssertionTypePreventUserIdleSystemSleep`: the display still sleeps on its own schedule.
@MainActor
public final class SystemIdleSleepAssertion: IdleSleepAssertion {
    private var id = IOPMAssertionID(0)

    public init() {}

    public func hold() -> Bool {
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Sphyrna: a session is working" as CFString, &id)
        if result != kIOReturnSuccess { LoomLog.error(.lifecycle, "The keep-awake assertion was refused (\(result))") }
        return result == kIOReturnSuccess
    }

    public func release() {
        IOPMAssertionRelease(id)
        id = 0
    }
}

/// Holds at most one assertion while the setting asks for it and any session works, and lets it go as soon as neither holds. It
/// follows the working count the app already tracks and keeps no timer.
@MainActor
public final class KeepAwakeController {
    private let assertion: any IdleSleepAssertion
    public private(set) var isHeld = false
    private var setting = KeepAwakeSetting.off
    private var workingSessions = 0

    public init(assertion: any IdleSleepAssertion) { self.assertion = assertion }

    public func settingChanged(_ setting: KeepAwakeSetting) {
        self.setting = setting
        apply()
    }

    public func workingChanged(_ count: Int) {
        workingSessions = count
        apply()
    }

    /// At quit.
    public func stop() {
        setting = .off
        apply()
    }

    private func apply() {
        let wanted = setting == .whileWorking && workingSessions > 0
        if wanted, !isHeld {
            isHeld = assertion.hold()
        } else if !wanted, isHeld {
            assertion.release()
            isHeld = false
        }
    }
}
