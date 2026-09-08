import Foundation
import AppKit

/// Section 6. Resolves process identity and assigns each process to an application
/// group using the Section 6.2 precedence ladder.
///
/// Grouping must be deterministic, explainable and reversible in the detail view, so
/// every assignment records the `GroupingReason` that produced it.
public final class ApplicationGrouper: @unchecked Sendable {
    /// Section 10.2: bounded caches for icons and process identities.
    private var bundleCache: [String: BundleInfo] = [:]
    private var identityCache: [ProcessKey: ProcessIdentity] = [:]
    private let cacheLimit = 4096
    private let lock = NSLock()

    struct BundleInfo: Sendable {
        let bundleIdentifier: String?
        let displayName: String
        let bundleURL: URL
    }

    public init() {}

    /// Snapshot of what NSWorkspace knows, captured once per cycle on the main actor
    /// and passed in — the resolver itself runs off the main thread.
    public struct WorkspaceSnapshot: Sendable {
        /// PID -> (bundle identifier, localized name, bundle URL, isActive)
        public let runningApplications: [pid_t: RunningApplication]

        public struct RunningApplication: Sendable {
            public let bundleIdentifier: String?
            public let localizedName: String
            public let bundleURL: URL?
            public let isActive: Bool
            public let isHidden: Bool

            public init(bundleIdentifier: String?, localizedName: String, bundleURL: URL?, isActive: Bool, isHidden: Bool) {
                self.bundleIdentifier = bundleIdentifier
                self.localizedName = localizedName
                self.bundleURL = bundleURL
                self.isActive = isActive
                self.isHidden = isHidden
            }
        }

        public init(runningApplications: [pid_t: RunningApplication]) {
            self.runningApplications = runningApplications
        }

        @MainActor
        public static func capture() -> WorkspaceSnapshot {
            var map: [pid_t: RunningApplication] = [:]
            for app in NSWorkspace.shared.runningApplications {
                map[app.processIdentifier] = RunningApplication(
                    bundleIdentifier: app.bundleIdentifier,
                    localizedName: app.localizedName ?? "Unknown",
                    bundleURL: app.bundleURL,
                    isActive: app.isActive,
                    isHidden: app.isHidden
                )
            }
            return WorkspaceSnapshot(runningApplications: map)
        }
    }

    /// Resolves one process to a full identity including its application group.
    public func resolve(
        raw: ProcessCollector.RawIdentity,
        key: ProcessKey,
        workspace: WorkspaceSnapshot,
        allRawIdentities: [ProcessKey: ProcessCollector.RawIdentity]
    ) -> ProcessIdentity {
        lock.lock()
        if let cached = identityCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let executable = raw.executablePath.map {
            ExecutableIdentity(executablePath: $0, signingIdentifier: nil)
        }

        let resolution = resolveGroup(
            raw: raw,
            executable: executable,
            workspace: workspace,
            allRawIdentities: allRawIdentities
        )

        let identity = ProcessIdentity(
            key: key,
            name: displayName(for: raw),
            executable: executable,
            parentPID: raw.parentPID,
            userID: raw.userID,
            groupID: resolution.id,
            groupDisplayName: resolution.displayName,
            groupingReason: resolution.reason,
            bundleURL: resolution.bundleURL,
            isPrincipalProcess: resolution.isPrincipal
        )

        lock.lock()
        if identityCache.count >= cacheLimit { identityCache.removeAll(keepingCapacity: true) }
        identityCache[key] = identity
        lock.unlock()
        return identity
    }

    struct GroupResolution {
        let id: ApplicationGroupID
        let displayName: String
        let reason: GroupingReason
        let bundleURL: URL?
        let isPrincipal: Bool
    }

    /// Section 6.2, in precedence order. The first rule that produces a safe answer wins.
    private func resolveGroup(
        raw: ProcessCollector.RawIdentity,
        executable: ExecutableIdentity?,
        workspace: WorkspaceSnapshot,
        allRawIdentities: [ProcessKey: ProcessCollector.RawIdentity]
    ) -> GroupResolution {
        // 1. Exact bundle ownership reported by NSRunningApplication.
        if let app = workspace.runningApplications[raw.pid] {
            let id = app.bundleIdentifier.map { ApplicationGroupID(bundle: $0) }
                ?? executable.map { ApplicationGroupID(executable: $0) }
                ?? ApplicationGroupID(bundle: app.localizedName)
            return GroupResolution(
                id: id,
                displayName: app.localizedName,
                reason: .bundleOwnership,
                bundleURL: app.bundleURL,
                isPrincipal: true
            )
        }

        // 2. The executable lives inside an .app bundle — this is what pulls
        //    "Google Chrome Helper (Renderer)" under "Google Chrome" (Section 6.3).
        if let path = raw.executablePath, let bundle = enclosingBundle(of: path) {
            let id = bundle.bundleIdentifier.map { ApplicationGroupID(bundle: $0) }
                ?? ApplicationGroupID(bundle: bundle.displayName)
            return GroupResolution(
                id: id,
                displayName: bundle.displayName,
                reason: .bundlePathContainment,
                bundleURL: bundle.bundleURL,
                isPrincipal: false
            )
        }

        // 3. Helper relationship by bundle identifier prefix, for helpers that live
        //    outside their parent's bundle but share its identifier namespace.
        if let path = raw.executablePath,
           let helperBundle = enclosingBundle(of: path),
           let helperID = helperBundle.bundleIdentifier,
           let parentApp = workspace.runningApplications.values.first(where: {
               guard let candidate = $0.bundleIdentifier, candidate != helperID else { return false }
               return helperID.hasPrefix(candidate + ".")
           }),
           let parentID = parentApp.bundleIdentifier {
            return GroupResolution(
                id: ApplicationGroupID(bundle: parentID),
                displayName: parentApp.localizedName,
                reason: .helperBundlePrefix,
                bundleURL: parentApp.bundleURL,
                isPrincipal: false
            )
        }

        // 4. Parent chain, for short-lived helpers. Section 6.2 warns specifically
        //    against grouping under shells: a script run from Terminal must not be
        //    attributed to Terminal, or every command a user types inflates one app.
        if raw.parentPID > 1,
           let parentApp = workspace.runningApplications[raw.parentPID],
           let parentID = parentApp.bundleIdentifier,
           !Self.shellLikeBundleIDs.contains(parentID),
           !isShellLike(parentPID: raw.parentPID, in: allRawIdentities) {
            return GroupResolution(
                id: ApplicationGroupID(bundle: parentID),
                displayName: parentApp.localizedName,
                reason: .parentChain,
                bundleURL: parentApp.bundleURL,
                isPrincipal: false
            )
        }

        // 5. Standalone executable: no safe application association exists.
        let id = executable.map { ApplicationGroupID(executable: $0) }
            ?? ApplicationGroupID(bundle: raw.name)
        return GroupResolution(
            id: id,
            displayName: displayName(for: raw),
            reason: .standaloneExecutable,
            bundleURL: nil,
            isPrincipal: true
        )
    }

    /// Terminals and shells launch unrelated user work; attributing that work to them
    /// would be actively misleading (Section 6.2).
    static let shellLikeBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "io.alacritty",
    ]

    static let shellExecutableNames: Set<String> = [
        "bash", "zsh", "sh", "fish", "csh", "tcsh", "dash", "ksh", "login", "tmux", "screen",
    ]

    private func isShellLike(parentPID: pid_t, in identities: [ProcessKey: ProcessCollector.RawIdentity]) -> Bool {
        guard let parent = identities.values.first(where: { $0.pid == parentPID }) else { return false }
        return Self.shellExecutableNames.contains(parent.name)
    }

    /// Walks up from an executable path to the nearest enclosing .app bundle.
    ///
    /// Nested bundles are common (Chrome ships its helpers inside its own Frameworks
    /// directory), so the *outermost* .app on the path is the owning application —
    /// that is what makes helpers roll up instead of appearing as their own apps.
    func enclosingBundle(of executablePath: String) -> BundleInfo? {
        lock.lock()
        if let cached = bundleCache[executablePath] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let components = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        guard let outermost = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = "/" + components[1...outermost].joined(separator: "/")
        let url = URL(fileURLWithPath: bundlePath)
        guard let bundle = Bundle(url: url) else { return nil }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let info = BundleInfo(
            bundleIdentifier: bundle.bundleIdentifier,
            displayName: name,
            bundleURL: url
        )

        lock.lock()
        if bundleCache.count >= cacheLimit { bundleCache.removeAll(keepingCapacity: true) }
        bundleCache[executablePath] = info
        lock.unlock()
        return info
    }

    private func displayName(for raw: ProcessCollector.RawIdentity) -> String {
        // proc_name truncates at 16 characters; the executable basename is the fuller
        // name when we have a path.
        if let path = raw.executablePath {
            let base = (path as NSString).lastPathComponent
            if Self.isMeaninglessBinaryName(base) {
                // Self-updating tools (Claude Code, Cursor, Electron updaters) exec a
                // binary named for its version, so the basename is "2.1.263". Walk up
                // to the nearest directory that actually names the program — a row
                // labelled with a bare version number identifies nothing.
                if let meaningful = Self.namedAncestor(of: path) { return meaningful }
            }
            if base.count > raw.name.count { return base }
        }
        return raw.name
    }

    /// A name is meaningless as a row label if it carries no letters — a bare version
    /// like "2.1.263", a numeric build id, or a hash-like directory.
    static func isMeaninglessBinaryName(_ name: String) -> Bool {
        guard !name.isEmpty else { return true }
        return !name.contains { $0.isLetter }
    }

    /// The closest ancestor directory whose name identifies the program, skipping
    /// generic container directories that would be equally uninformative.
    static func namedAncestor(of path: String) -> String? {
        let uninformative: Set<String> = [
            "bin", "sbin", "libexec", "MacOS", "Contents", "Resources", "Helpers",
            "versions", "Versions", "current", "Current", "node_modules", "dist", "build",
        ]
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        // Bounded walk: never climb past a couple of levels into the filesystem root.
        for _ in 0..<4 {
            let component = url.lastPathComponent
            if component.isEmpty || component == "/" { return nil }
            if !uninformative.contains(component), !isMeaninglessBinaryName(component) {
                return component
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// Section 3.2 / 7.3: drop identities for processes that no longer exist so the
    /// cache cannot serve a stale identity to a reused PID.
    public func pruneCache(livingKeys: Set<ProcessKey>) {
        lock.lock()
        identityCache = identityCache.filter { livingKeys.contains($0.key) }
        lock.unlock()
    }

    /// Builds application rows from this cycle's per-process metrics.
    public func group(
        metrics: [ProcessIntervalMetrics],
        workspace: WorkspaceSnapshot,
        thresholds: StatusThresholds = .init()
    ) -> [ApplicationGroup] {
        var buckets: [ApplicationGroupID: [ProcessIntervalMetrics]] = [:]
        for metric in metrics {
            buckets[metric.identity.groupID, default: []].append(metric)
        }

        return buckets.map { id, members in
            // Prefer the principal process's name: a group found via its helper should
            // still be titled "Google Chrome", not "Google Chrome Helper".
            let principal = members.first { $0.identity.isPrincipalProcess } ?? members[0]
            let sorted = members.sorted {
                ($0.energyWatts.value ?? 0) > ($1.energyWatts.value ?? 0)
            }
            let group = ApplicationGroup(
                id: id,
                displayName: principal.identity.groupDisplayName,
                bundleURL: principal.identity.bundleURL ?? members.compactMap(\.identity.bundleURL).first,
                members: sorted,
                status: .normal
            )
            return ApplicationGroup(
                id: group.id,
                displayName: group.displayName,
                bundleURL: group.bundleURL,
                members: sorted,
                status: status(for: group, workspace: workspace, thresholds: thresholds)
            )
        }
    }

    public struct StatusThresholds: Sendable {
        public var highEnergyWatts: Double
        public var highMemoryBytes: UInt64
        public var backgroundCPUPercent: Double

        public init(
            highEnergyWatts: Double = 1.0,
            highMemoryBytes: UInt64 = 2 * 1024 * 1024 * 1024,
            backgroundCPUPercent: Double = 15
        ) {
            self.highEnergyWatts = highEnergyWatts
            self.highMemoryBytes = highMemoryBytes
            self.backgroundCPUPercent = backgroundCPUPercent
        }
    }

    private func status(
        for group: ApplicationGroup,
        workspace: WorkspaceSnapshot,
        thresholds: StatusThresholds
    ) -> ApplicationStatus {
        if let watts = group.totalEnergyWatts.value, watts >= thresholds.highEnergyWatts {
            return .highEnergy
        }
        // Section 8.3 "hidden background load": visible-but-idle apps are normal;
        // an app burning CPU while hidden is the interesting case.
        let isForeground = group.members.contains { member in
            workspace.runningApplications[member.key.pid]?.isActive ?? false
        }
        let isHidden = group.members.allSatisfy { member in
            workspace.runningApplications[member.key.pid]?.isHidden ?? true
        }
        if !isForeground, isHidden,
           let cpu = group.totalCPUPercent.value, cpu >= thresholds.backgroundCPUPercent {
            return .backgroundActivity
        }
        if let bytes = group.totalFootprintBytes.value, bytes >= thresholds.highMemoryBytes {
            return .highMemory
        }
        return .normal
    }
}
