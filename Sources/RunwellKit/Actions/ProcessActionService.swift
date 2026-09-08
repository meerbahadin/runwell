import Foundation
import AppKit

/// Section 8.4. Quit, force quit, reveal and copy details.
///
/// Section 1.3: prefer normal termination and clear confirmation; protect critical
/// operating-system processes.
public struct ProcessActionService: Sendable {
    private let policy = ProtectedProcessPolicy()
    public init() {}

    public enum ActionError: LocalizedError, Equatable {
        case blocked(String)
        case processNotFound
        case terminationFailed(String)
        case pathUnavailable

        public var errorDescription: String? {
            switch self {
            case .blocked(let reason): reason
            case .processNotFound: "That process is no longer running."
            case .terminationFailed(let reason): reason
            case .pathUnavailable: "The location of this item is not accessible."
            }
        }
    }

    public func protection(for identity: ProcessIdentity) -> ProtectedProcessPolicy.Protection {
        policy.evaluate(identity: identity)
    }

    /// Section 8.4 "Quit": a normal application termination request. For a bundled
    /// app this is the same polite request the Dock sends, so the app can prompt to
    /// save; for anything else it is SIGTERM, which is the equivalent courtesy.
    @MainActor
    public func quit(identity: ProcessIdentity) -> Result<Void, ActionError> {
        if case .blocked(let reason) = policy.evaluate(identity: identity) {
            return .failure(.blocked(reason))
        }
        if let app = NSRunningApplication(processIdentifier: identity.key.pid) {
            return app.terminate() ? .success(()) : .failure(.terminationFailed(
                "\(identity.name) did not accept the quit request."
            ))
        }
        return signal(SIGTERM, to: identity)
    }

    /// Section 8.4 "Force quit": never a default, and always behind a confirmation the
    /// caller must have already shown.
    @MainActor
    public func forceQuit(identity: ProcessIdentity, userConfirmed: Bool) -> Result<Void, ActionError> {
        guard userConfirmed else {
            return .failure(.blocked("Force quit requires confirmation."))
        }
        if case .blocked(let reason) = policy.evaluate(identity: identity) {
            return .failure(.blocked(reason))
        }
        if let app = NSRunningApplication(processIdentifier: identity.key.pid) {
            return app.forceTerminate() ? .success(()) : .failure(.terminationFailed(
                "\(identity.name) could not be forced to quit."
            ))
        }
        return signal(SIGKILL, to: identity)
    }

    // MARK: - Group actions

    /// The outcome of quitting a whole application group, reported per process so the
    /// UI can say exactly what happened rather than claiming a blanket success.
    public struct GroupOutcome: Sendable, Equatable {
        public struct Failure: Sendable, Equatable {
            public let name: String
            public let reason: String
        }
        /// Processes that accepted the request.
        public let terminated: [String]
        /// Processes the policy refused to touch (Section 9.2), left running.
        public let skipped: [Failure]
        /// Processes that were asked but did not comply.
        public let failed: [Failure]
        /// Processes that had already exited — not an error, and common when quitting
        /// a group, since terminating the principal often takes its helpers with it.
        public let alreadyGone: Int

        public var isCompleteSuccess: Bool { skipped.isEmpty && failed.isEmpty }
    }

    /// Section 8.4 applied to an application group: quit every process Runwell is
    /// allowed to quit, and report the rest honestly.
    ///
    /// Protection is evaluated per process, never per group, so a group containing one
    /// blocked helper still quits the rest instead of being refused wholesale — and a
    /// blocked process is never terminated as a side effect of a group action.
    @MainActor
    public func quitGroup(_ group: ApplicationGroup) -> GroupOutcome {
        terminateGroup(group, force: false)
    }

    /// Force quit for a whole group. `userConfirmed` carries the same meaning as the
    /// single-process call: the caller must already have shown a confirmation naming
    /// how many processes will be killed.
    @MainActor
    public func forceQuitGroup(_ group: ApplicationGroup, userConfirmed: Bool) -> GroupOutcome {
        guard userConfirmed else {
            return GroupOutcome(
                terminated: [], skipped: [],
                failed: [.init(name: group.displayName, reason: "Force quit requires confirmation.")],
                alreadyGone: 0
            )
        }
        return terminateGroup(group, force: true)
    }

    @MainActor
    private func terminateGroup(_ group: ApplicationGroup, force: Bool) -> GroupOutcome {
        var terminated: [String] = []
        var skipped: [GroupOutcome.Failure] = []
        var failed: [GroupOutcome.Failure] = []
        var alreadyGone = 0

        // Helpers first, principal last. A browser or Electron app respawns a helper
        // it notices dying, so killing the principal first would leave orphans behind
        // that the next sample picks straight back up.
        let ordered = group.members.sorted { a, b in
            !a.identity.isPrincipalProcess && b.identity.isPrincipalProcess
        }

        for member in ordered {
            let identity = member.identity

            if case .blocked(let reason) = policy.evaluate(identity: identity) {
                skipped.append(.init(name: identity.name, reason: reason))
                continue
            }

            // Re-check liveness per process: quitting the principal frequently takes
            // its helpers with it, so by the time we reach them they are simply gone.
            guard Self.stillAlive(identity) else {
                alreadyGone += 1
                continue
            }

            let result = force
                ? forceQuit(identity: identity, userConfirmed: true)
                : quit(identity: identity)

            switch result {
            case .success:
                terminated.append(identity.name)
            case .failure(.processNotFound):
                alreadyGone += 1
            case .failure(let error):
                failed.append(.init(name: identity.name, reason: error.errorDescription ?? "Unknown error."))
            }
        }

        return GroupOutcome(
            terminated: terminated, skipped: skipped,
            failed: failed, alreadyGone: alreadyGone
        )
    }

    private func signal(_ sig: Int32, to identity: ProcessIdentity) -> Result<Void, ActionError> {
        // Re-check that the PID still refers to the same process. Between the user
        // reading the row and clicking, a PID can be reused — this is the Section 9.2
        // metric-spoofing risk applied to an irreversible action.
        guard Self.stillAlive(identity) else { return .failure(.processNotFound) }
        guard kill(identity.key.pid, sig) == 0 else {
            return .failure(.terminationFailed(String(cString: strerror(errno))))
        }
        return .success(())
    }

    static func stillAlive(_ identity: ProcessIdentity) -> Bool {
        guard let bsd = ProcessCollector.bsdInfo(identity.key.pid) else { return false }
        return ProcessCollector.startAbsoluteTime(bsd) == identity.key.startAbsoluteTime
    }

    /// Section 8.4 "Reveal".
    @MainActor
    public func revealInFinder(identity: ProcessIdentity) -> Result<Void, ActionError> {
        let target = identity.bundleURL ?? identity.executable.map { URL(fileURLWithPath: $0.executablePath) }
        guard let target, FileManager.default.fileExists(atPath: target.path) else {
            return .failure(.pathUnavailable)
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
        return .success(())
    }

    /// Section 8.4 "Copy details" — a privacy-reviewed diagnostic summary.
    ///
    /// Section 9.1 / 8.4: command-line arguments are never collected, and home
    /// directory names are stripped from the path.
    public func diagnosticSummary(
        for group: ApplicationGroup,
        coverage: EnergyCoverage
    ) -> String {
        var lines: [String] = []
        lines.append("Runwell diagnostic summary")
        lines.append("Application: \(group.displayName)")
        lines.append("Processes: \(group.processCount)")

        let energy = group.totalEnergyWatts
        lines.append("Energy: \(energy.formatted("%.2f", suffix: " W")) (\(energy.provenance.badge))")

        let cpu = group.totalCPUPercent
        lines.append("CPU: \(cpu.formatted("%.1f", suffix: "%")) (\(cpu.provenance.badge))")

        if let bytes = group.totalFootprintBytes.value {
            lines.append("Memory footprint: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))")
        } else {
            lines.append("Memory footprint: —")
        }

        let share = coverage.measuredAppShare(of: group)
        // Section 3.1 mandates this exact wording rather than "battery percentage used".
        lines.append("\(EnergyCoverage.shareLabel): \(share.map { $0 * 100 }.formatted("%.1f", suffix: "%"))")

        lines.append("")
        lines.append("Processes in this group:")
        for member in group.members {
            let watts = member.energyWatts.formatted("%.2f", suffix: " W")
            let percent = member.cpuPercent.formatted("%.1f", suffix: "%")
            // Redacted path only, and no command-line arguments.
            let path = member.identity.executable?.redactedPath ?? "—"
            lines.append("  \(member.identity.name) — \(watts), \(percent) CPU — \(path)")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    public func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
