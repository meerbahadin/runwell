import Foundation

/// Section 6.1. Unique for the lifetime of exactly one process.
///
/// macOS reuses PIDs, so a PID alone is not an identity (Section 3.2). Pairing it
/// with the process start time makes a key that cannot silently follow a PID onto
/// a different program — the `metricSpoofing` mitigation in Section 9.2.
public struct ProcessKey: Hashable, Codable, Sendable {
    public let pid: pid_t
    public let startAbsoluteTime: UInt64

    public init(pid: pid_t, startAbsoluteTime: UInt64) {
        self.pid = pid
        self.startAbsoluteTime = startAbsoluteTime
    }
}

/// Section 6.1. Distinguishes binaries across updates.
public struct ExecutableIdentity: Hashable, Codable, Sendable {
    public let executablePath: String
    /// Code-signing identity when the binary is signed; nil for unsigned executables.
    public let signingIdentifier: String?

    public init(executablePath: String, signingIdentifier: String?) {
        self.executablePath = executablePath
        self.signingIdentifier = signingIdentifier
    }

    /// Section 9.1: executable paths are reduced or hashed in history, and
    /// user-directory names are removed from exports.
    public var redactedPath: String {
        Self.redact(executablePath)
    }

    public static func redact(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        // /Users/someone/... belonging to another account.
        if path.hasPrefix("/Users/") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count > 3 {
                return "/Users/<user>/" + parts.dropFirst(3).joined(separator: "/")
            }
        }
        return path
    }
}

/// Section 6.1. Stable grouping and history key: the owning bundle identifier, or
/// the executable identity when no bundle owns the process.
public struct ApplicationGroupID: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bundle
        case executable
    }

    public let kind: Kind
    public let value: String

    public init(bundle identifier: String) {
        self.kind = .bundle
        self.value = identifier
    }

    public init(executable identity: ExecutableIdentity) {
        self.kind = .executable
        self.value = identity.signingIdentifier ?? identity.redactedPath
    }

    /// Stable primary key for history rows. Section 9.1: `value` is already either a
    /// bundle identifier or a redacted path, so nothing here carries a home directory.
    public var storageKey: String { "\(kind.rawValue):\(value)" }

    /// The bundle identifier when this group is one, and nil for a bare executable.
    public var bundleIdentifier: String? { kind == .bundle ? value : nil }
}

/// Section 6.1 / 7.3. Created at every collector start or resume boundary so that
/// deltas are never bridged across sleep, reboot or a collector reset.
public struct SampleSessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init() { self.rawValue = UUID() }
}

/// Why a process ended up in the group it did. Section 6 requires grouping to be
/// deterministic *and explainable* — this is shown in the process detail view.
public enum GroupingReason: String, Codable, Sendable {
    case bundleOwnership
    case bundlePathContainment
    case helperBundlePrefix
    case parentChain
    case standaloneExecutable

    public var explanation: String {
        switch self {
        case .bundleOwnership: "Reported by macOS as part of this application."
        case .bundlePathContainment: "Runs from inside this application's bundle."
        case .helperBundlePrefix: "Shares this application's bundle identifier prefix."
        case .parentChain: "Was launched by this application."
        case .standaloneExecutable: "Not associated with any application bundle."
        }
    }

    /// Section 6.2 precedence, lowest number wins. A later cheap-but-weak signal
    /// must never override an earlier authoritative one.
    public var precedence: Int {
        switch self {
        case .bundleOwnership: 0
        case .bundlePathContainment: 1
        case .helperBundlePrefix: 2
        case .parentChain: 3
        case .standaloneExecutable: 4
        }
    }
}

/// A process's resolved identity: who it is, and which application it belongs to.
public struct ProcessIdentity: Sendable, Hashable {
    public let key: ProcessKey
    public let name: String
    public let executable: ExecutableIdentity?
    public let parentPID: pid_t
    public let userID: uid_t
    public let groupID: ApplicationGroupID
    public let groupDisplayName: String
    public let groupingReason: GroupingReason
    public let bundleURL: URL?
    /// True when the process is the user-visible application itself rather than a helper.
    public let isPrincipalProcess: Bool

    public init(
        key: ProcessKey,
        name: String,
        executable: ExecutableIdentity?,
        parentPID: pid_t,
        userID: uid_t,
        groupID: ApplicationGroupID,
        groupDisplayName: String,
        groupingReason: GroupingReason,
        bundleURL: URL?,
        isPrincipalProcess: Bool
    ) {
        self.key = key
        self.name = name
        self.executable = executable
        self.parentPID = parentPID
        self.userID = userID
        self.groupID = groupID
        self.groupDisplayName = groupDisplayName
        self.groupingReason = groupingReason
        self.bundleURL = bundleURL
        self.isPrincipalProcess = isPrincipalProcess
    }
}
