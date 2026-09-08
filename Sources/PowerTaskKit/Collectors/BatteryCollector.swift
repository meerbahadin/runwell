import Foundation
import IOKit.ps

/// Section 5.6. Battery percentage, power-source state, charging status and the
/// OS-provided time estimates.
///
/// The spec deliberately scopes this to the power-source API. Battery health,
/// cycle count and instantaneous pack power need a separate compatibility study
/// because the registry keys commonly used for them are less stable, so they are
/// not read here.
public struct BatteryCollector: Sendable {
    public init() {}

    public func hasBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { return true }
        }
        return false
    }

    public func capture() -> BatterySnapshot {
        let capturedAt = MonotonicInstant.now()

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return unavailableSnapshot(at: capturedAt, reason: .notSupportedOnThisHardware)
        }

        // The power-source *type* tells us where the Mac is drawing from, and is
        // reported even on desktops with no battery at all.
        let providingSource = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        let onWallPower = providingSource == kIOPSACPowerValue

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int
            let max = description[kIOPSMaxCapacityKey] as? Int
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false

            let percentage: IntervalMetric<Double>
            if let current, let max, max > 0 {
                percentage = .measured(Double(current) / Double(max) * 100)
            } else {
                percentage = .unavailable(.notSupportedOnThisHardware)
            }

            // Section 5.10 marks this measured-or-estimated *by the OS*. PowerTask
            // passes the value through and never substitutes its own model.
            //
            // Three states are distinct and must not collapse into "0 minutes":
            //   - charged and on AC: there is no meaningful estimate to give;
            //   - macOS still calculating: it reports -1, a genuine "not yet known";
            //   - a real estimate: pass it through.
            // A literal 0 from the OS while charged is "nothing left to charge", not
            // "no runtime left" — rendering it as 0m would read as an empty battery.
            let timeRemaining: IntervalMetric<TimeInterval>
            if isCharged || (onWallPower && !isCharging) {
                timeRemaining = .unavailable(.notSupportedOnThisHardware)
            } else {
                let key = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
                let minutes = description[key] as? Int
                if let minutes, minutes > 0 {
                    timeRemaining = .init(value: TimeInterval(minutes) * 60, provenance: .measured, confidence: 0.7)
                } else {
                    timeRemaining = .unavailable(.awaitingSecondSample)
                }
            }

            return BatterySnapshot(
                percentage: percentage,
                powerSource: onWallPower ? .wallPower : .battery,
                isCharging: isCharging,
                isCharged: isCharged,
                isPresent: true,
                timeRemaining: timeRemaining,
                capturedAt: capturedAt
            )
        }

        // Section 2.3: desktop Macs run in resource-monitor mode, which is a valid
        // state rather than an error.
        return BatterySnapshot(
            percentage: .unavailable(.notSupportedOnThisHardware),
            powerSource: onWallPower ? .wallPower : .unknown,
            isCharging: false,
            isPresent: false,
            timeRemaining: .unavailable(.notSupportedOnThisHardware),
            capturedAt: capturedAt
        )
    }

    private func unavailableSnapshot(at instant: MonotonicInstant, reason: UnavailableReason) -> BatterySnapshot {
        BatterySnapshot(
            percentage: .unavailable(reason),
            powerSource: .unknown,
            isCharging: false,
            isPresent: false,
            timeRemaining: .unavailable(reason),
            capturedAt: instant
        )
    }
}
