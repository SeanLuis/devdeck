import Foundation
import IOKit.ps

/// Battery and heat, as macOS reports them. macOS does not publish temperatures in degrees to apps;
/// the thermal state (how hard the system is throttling) is the supported signal.
public struct PowerStatus: Hashable, Sendable {
    /// 0–100; nil on a Mac without battery.
    public var batteryPercent: Double?
    public var charging = false
    /// Plugged in (charging or full).
    public var onAC = true
    /// Minutes until empty, when macOS has an estimate.
    public var minutesLeft: Int?
    /// 0 nominal · 1 fair · 2 serious · 3 critical
    public var thermalLevel = 0
    public var lowPowerMode = false

    public init() {}
    public static let unknown = PowerStatus()

    public var hasBattery: Bool { batteryPercent != nil }

    public var thermalLabel: String {
        switch thermalLevel {
        case 0: return "normal"
        case 1: return "templado"
        case 2: return "caliente"
        default: return "crítica"
        }
    }

    public static func read() -> PowerStatus {
        var status = PowerStatus()
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: status.thermalLevel = 0
        case .fair: status.thermalLevel = 1
        case .serious: status.thermalLevel = 2
        case .critical: status.thermalLevel = 3
        @unknown default: status.thermalLevel = 0
        }
        status.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return status }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let parsed = parse(description) {
                status.batteryPercent = parsed.percent
                status.charging = parsed.charging
                status.onAC = parsed.onAC
                status.minutesLeft = parsed.minutesLeft
                break
            }
        }
        return status
    }

    /// One power source dictionary → battery figures; nil when it is not an internal battery.
    static func parse(_ description: [String: Any]) -> (percent: Double, charging: Bool, onAC: Bool, minutesLeft: Int?)? {
        guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
              let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, maximum > 0 else { return nil }
        let onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let minutes = (description[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue
        return (min(100, current / maximum * 100), (description[kIOPSIsChargingKey] as? Bool) ?? false, onAC,
                onAC ? nil : minutes.flatMap { $0 > 0 ? $0 : nil })
    }
}
