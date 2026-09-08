import Foundation
import Darwin

/// Section 9.2 / 8.4. Prevents the user from terminating something that would
/// destabilize the system, and makes force quit a deliberate act rather than an
/// accidental one.
public struct ProtectedProcessPolicy: Sendable {
    public init() {}

    public enum Protection: Sendable, Equatable {
        /// An ordinary user application: normal quit needs no confirmation.
        case unprotected
        /// Terminable, but only behind an explicit confirmation.
        case requiresConfirmation(String)
        /// Never terminable from Runwell.
        case blocked(String)

        public var isBlocked: Bool {
            if case .blocked = self { return true }
            return false
        }
    }

    /// Killing any of these produces an unusable or logged-out Mac.
    static let criticalProcessNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "systemstats",
        "syslogd", "notifyd", "opendirectoryd", "securityd", "configd", "diskarbitrationd",
        "coreaudiod", "hidd", "powerd", "logd", "UserEventAgent", "distnoted",
        "cfprefsd", "mds", "mds_stores", "kextd", "watchdogd", "SystemUIServer", "Dock", "Finder",
    ]

    public func evaluate(identity: ProcessIdentity) -> Protection {
        let name = identity.name

        if Self.criticalProcessNames.contains(name) {
            return .blocked("\(name) is a critical macOS process. Quitting it would make your Mac unusable.")
        }

        // Runwell must not offer to kill Runwell.
        if identity.key.pid == getpid() {
            return .blocked("This is Runwell itself.")
        }

        // Section 2.2 / 8.4: block or strongly warn for system and root processes.
        if identity.userID == 0 {
            return .blocked("This process runs as root. Runwell does not terminate system-owned processes.")
        }

        if identity.userID != getuid() {
            return .blocked("This process belongs to another user account.")
        }

        // Anything shipped inside the OS, even when running as the user.
        if let path = identity.executable?.executablePath,
           path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") {
            return .requiresConfirmation("\(name) is part of macOS. Quitting it may affect system features.")
        }

        if !identity.isPrincipalProcess {
            return .requiresConfirmation(
                "\(name) is a helper process of \(identity.groupDisplayName). Quitting it may cause the app to misbehave."
            )
        }

        return .unprotected
    }
}
