import Foundation
import IOKit.pwr_mgt
import CoreGraphics

/// Section 5.9. Which processes are currently preventing this Mac from sleeping.
///
/// Reads `IOPMCopyAssertionsByProcess`, a public IOKit interface that returns
/// assertions keyed by process id. The specification held this rule back because the
/// only obvious source was the text output of `pmset -g assertions`; parsing another
/// tool's formatting would break silently whenever Apple changed it, and a
/// misparse here does not produce a missing number — it accuses the wrong app.
/// This interface is documented, unprivileged, and already keyed by pid, so the
/// attribution is the system's rather than ours.
public struct SleepAssertionCollector: Sendable {
    /// One process holding one sleep-preventing assertion.
    public struct Assertion: Sendable, Equatable, Identifiable {
        public let pid: pid_t
        public let kind: Kind
        /// The assertion's own description, e.g. "playing audio". Shown as evidence
        /// so the claim arrives with the system's own words for it.
        public let name: String

        /// A process can hold more than one assertion, so the pid alone is not
        /// unique; the name distinguishes them.
        public var id: String { "\(pid):\(kind.rawValue):\(name)" }

        public init(pid: pid_t, kind: Kind, name: String) {
            self.pid = pid
            self.kind = kind
            self.name = name
        }
    }

    /// Only the assertion types that actually keep hardware awake. macOS defines
    /// many more (network activity, background tasks) that do not stop sleep and
    /// would be false accusations.
    public enum Kind: String, Sendable, Equatable {
        /// Stops the whole machine idling to sleep. This is the one that runs a
        /// laptop hot in a closed bag.
        case systemSleep
        /// Stops the display sleeping, which still costs a lot of power.
        case displaySleep

        public var isSystemLevel: Bool { self == .systemSleep }
    }

    public init() {}

    /// Section 4: never fabricate. An unreadable interface returns nil — meaning
    /// "unknown" — rather than an empty list, which would mean "nothing is holding
    /// an assertion" and is a different claim entirely.
    public func capture() -> [Assertion]? {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return nil }

        var assertions: [Assertion] = []
        for (processID, entries) in byProcess {
            let pid = pid_t(truncating: processID)
            for entry in entries {
                guard let type = entry[kIOPMAssertionTypeKey] as? String,
                      let kind = Self.kind(for: type) else { continue }
                let name = entry[kIOPMAssertionNameKey] as? String ?? "no reason given"
                assertions.append(Assertion(pid: pid, kind: kind, name: name))
            }
        }
        return assertions
    }

    /// Maps the assertion type strings to the two kinds that matter. Anything else
    /// — background tasks, push service, network activity — does not prevent sleep
    /// and is deliberately ignored.
    static func kind(for type: String) -> Kind? {
        switch type {
        case kIOPMAssertionTypePreventUserIdleSystemSleep,
             kIOPMAssertionTypeNoIdleSleep:
            return .systemSleep
        case kIOPMAssertionTypePreventUserIdleDisplaySleep,
             kIOPMAssertionTypeNoDisplaySleep:
            return .displaySleep
        default:
            return nil
        }
    }

    /// Whether the interface answers at all on this Mac, for the capability probe.
    public func isAvailable() -> Bool { capture() != nil }

    /// Whether the display is currently asleep.
    ///
    /// This is what separates a problem from normal operation. An app holding an
    /// assertion while you are using the Mac is doing its job — a video call should
    /// keep the screen alive. The same assertion held once the screen has gone dark
    /// is the case that empties a battery in a closed bag, and it is the only one
    /// worth interrupting anyone about.
    public func displayIsAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
}
