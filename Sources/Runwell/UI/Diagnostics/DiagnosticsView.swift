import SwiftUI
import RunwellKit

/// Section 10.3. A local diagnostics page showing collector health without requiring
/// remote telemetry. Appendix F: the OS build and hardware identifier are recorded
/// here for local troubleshooting and never sent anywhere.
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading("Diagnostics")
                system
                Divider()
                collectors
                Divider()
                sampling
                Divider()
                sleepAssertions
                Divider()
                actions
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var system: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System").font(Theme.Typography.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("macOS build").foregroundStyle(.secondary)
                    Text(environment.capabilities.osBuild).monospaced()
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text(environment.capabilities.hardwareModel).monospaced()
                }
                GridRow {
                    Text("Logical cores").foregroundStyle(.secondary)
                    Text("\(environment.capabilities.logicalProcessorCount)").monospacedDigit()
                }
                GridRow {
                    Text("Battery").foregroundStyle(.secondary)
                    Text(environment.capabilities.hasBattery ? "Present" : "None — resource-monitor mode")
                }
            }
            .font(Theme.Typography.callout)
        }
    }

    /// The collector-health table. Section 10.2: a collector that fails is disabled
    /// independently and shows a visible reason rather than silently reporting zero.
    private var collectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Collectors").font(Theme.Typography.headline)
            ForEach(Collector.allCases, id: \.self) { collector in
                if let status = environment.capabilities.status(collector) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        // Section 8.5: never encode state with colour alone.
                        Image(systemName: status.available ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(status.available ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(collector.displayName).fontWeight(.medium)
                                ProvenanceBadge(provenance: status.provenance, compact: true)
                            }
                            Text(status.reason)
                                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .cardSurface()
                }
            }
        }
    }

    private var sampling: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sampler").font(Theme.Typography.headline)
            if let snapshot = environment.snapshot {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Mode").foregroundStyle(.secondary)
                        Text(snapshot.mode.description)
                    }
                    GridRow {
                        Text("Last cycle").foregroundStyle(.secondary)
                        // Section 10.1 budget: p95 collection under 25% of the interval.
                        let ms = Double(snapshot.cycleDuration.components.attoseconds) / 1e15
                            + Double(snapshot.cycleDuration.components.seconds) * 1000
                        Text(String(format: "%.0f ms of %.0f ms budget", ms,
                                    snapshot.mode.intervalSeconds * 250))
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Skipped cycles").foregroundStyle(.secondary)
                        // Section 10.2: a cycle is skipped rather than overlapped.
                        Text("\(snapshot.skippedCycles)").monospacedDigit()
                    }
                    GridRow {
                        Text("Groups").foregroundStyle(.secondary)
                        Text("\(snapshot.groups.count)").monospacedDigit()
                    }
                    GridRow {
                        Text("Unreadable processes").foregroundStyle(.secondary)
                        Text("\(snapshot.coverage.inaccessibleProcessCount)").monospacedDigit()
                    }
                }
                .font(Theme.Typography.callout)
            } else {
                Text("Waiting for the first sample…").foregroundStyle(.secondary)
            }
        }
    }

    /// Section 5.9. What is holding the machine awake right now, and whether the
    /// rule would act on it.
    ///
    /// The sleep-prevention rule only fires once the display has been asleep for
    /// five minutes, which is precisely when nobody can watch it happen. This panel
    /// makes the rule's inputs inspectable while the screen is on, so its behaviour
    /// can be checked without having to catch it in the act.
    private var sleepAssertions: some View {
        // The snapshot's own groups, not `environment.groups`: that one is the
        // table's view of the world, narrowed by the search field and re-sorted.
        // A diagnostic must not change with what is typed in a search box.
        //
        // captured/displayAsleep come from the same snapshot rather than a second,
        // independent IOKit probe made inside the view: `body` calling out to
        // hardware on every redraw was wasted work at best, and at worst could
        // read a state a moment removed from the one the rest of this screen
        // (and any insight raised from it) is describing.
        SleepAssertionPanel(
            groups: environment.snapshot?.groups ?? [],
            actions: environment.actions,
            captured: environment.snapshot?.sleepAssertions ?? nil,
            displayAsleep: environment.snapshot?.displayIsAsleep ?? false
        )
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Report").font(Theme.Typography.headline)
            Text("Copies the values on this page. Section 9.1: no process list, paths or command lines are included.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                environment.actions.copyToPasteboard(report)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
    }

    /// A redacted health report: capability state only, no process information.
    private var report: String {
        var lines = ["Runwell diagnostics"]
        lines.append("macOS build: \(environment.capabilities.osBuild)")
        lines.append("Model: \(environment.capabilities.hardwareModel)")
        lines.append("Cores: \(environment.capabilities.logicalProcessorCount)")
        lines.append("")
        lines.append("Collectors:")
        for collector in Collector.allCases {
            if let status = environment.capabilities.status(collector) {
                lines.append("  \(collector.displayName): \(status.available ? "available" : "unavailable") — \(status.reason)")
            }
        }
        if let snapshot = environment.snapshot {
            lines.append("")
            lines.append("Sampler: \(snapshot.mode.description), \(snapshot.groups.count) groups, \(snapshot.skippedCycles) skipped cycles")
        }
        return lines.joined(separator: "\n")
    }
}

/// Live view of the sleep-prevention rule's inputs. Extracted from the diagnostics
/// body so the list has its own type context: a `ForEach` over a locally-bound array
/// inside a large `@ViewBuilder` resolved to the `Binding` overload instead.
struct SleepAssertionPanel: View {
    let groups: [ApplicationGroup]
    let actions: ProcessActionService
    /// Read from the sampler's own snapshot rather than probed by this view: a
    /// second, independent IOKit call inside `body` re-ran on every redraw and
    /// could disagree with what the rest of the app — including any raised
    /// insight — was already describing for the same cycle.
    let captured: [SleepAssertionCollector.Assertion]?
    let displayAsleep: Bool

    @State private var confirming: SleepAssertionCollector.Assertion?
    @State private var outcome: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sleep prevention").font(Theme.Typography.headline)

            if let captured {
                let sleepers = captured.filter { $0.kind.isSystemLevel }

                Text(displayAsleep
                     ? "The display is off, so these are being judged."
                     : "The display is on, so none of these count yet — an app keeping the Mac awake while you are using it is not a problem.")
                    .font(Theme.Typography.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if sleepers.isEmpty {
                    Text("Nothing is preventing sleep.")
                        .font(Theme.Typography.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(sleepers) { assertion in
                        row(for: assertion, displayAsleep: displayAsleep)
                    }
                }
            } else {
                // Section 4: unreadable is unknown, not "nothing".
                Text("The power-assertion interface did not answer, so Runwell cannot tell.")
                    .font(Theme.Typography.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let outcome {
                Text(outcome)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            confirming.map { "Quit \(displayName(for: $0, member: memberProcess(for: $0)))?" } ?? "",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Quit", role: .destructive) {
                if let assertion = confirming { quit(assertion, force: false) }
                confirming = nil
            }
            // Section 8.4: force quit is never the default, but a process that
            // ignores a polite request is exactly the case this panel exists for —
            // caffeinate and its kind do not respond to a terminate.
            Button("Force Quit", role: .destructive) {
                if let assertion = confirming { quit(assertion, force: true) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Quit asks the process to stop and may be ignored. Force Quit ends it immediately — unsaved work will be lost.")
        }
    }

    /// Ends the process, and says plainly what happened either way.
    private func quit(_ assertion: SleepAssertionCollector.Assertion, force: Bool) {
        guard let member = memberProcess(for: assertion) else {
            outcome = "That process is no longer running."
            return
        }
        let name = member.identity.groupDisplayName
        let result = force
            ? actions.forceQuit(identity: member.identity, userConfirmed: true)
            : actions.quit(identity: member.identity)
        switch result {
        case .success:
            outcome = force
                ? "Force quit \(name)."
                : "Asked \(name) to quit. If it keeps holding the assertion, use Force Quit."
        case .failure(let error):
            // A refusal is reported, never swallowed: the policy exists for reasons
            // the user should be able to read.
            outcome = "Could not quit: \(error.localizedDescription)"
        }
    }

    private func row(
        for assertion: SleepAssertionCollector.Assertion, displayAsleep: Bool
    ) -> some View {
        let member = memberProcess(for: assertion)
        // Root-owned daemons like powerd are not in the application groups at all,
        // so an absent owner is itself evidence that this is a system process
        // rather than something the user launched.
        let isSystem = member.map { $0.identity.userID == 0 } ?? true
        let flagged = !isSystem && displayAsleep
        let protection = member.map { actions.protection(for: $0.identity) }
        let canQuit = protection.map { !$0.isBlocked } ?? false

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSystem ? "gearshape.fill" : "eye.fill")
                .foregroundStyle(flagged ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: assertion, member: member))
                    .fontWeight(.medium)
                Text(assertion.name)
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verdict(isSystem: isSystem, displayAsleep: displayAsleep))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(flagged ? .orange : .secondary)
            }
            Spacer(minLength: 0)

            // The whole point of naming the culprit is being able to stop it. The
            // protection policy still decides: a system daemon offers no button.
            if canQuit {
                Button("Quit") { confirming = assertion }
                    .font(Theme.Typography.caption)
                    .help("Quits this process so it stops holding the Mac awake.")
            }
        }
    }

    /// The process behind an assertion, if it belongs to an application group.
    private func memberProcess(
        for assertion: SleepAssertionCollector.Assertion
    ) -> ProcessIntervalMetrics? {
        for group in groups {
            if let match = group.members.first(where: { $0.key.pid == assertion.pid }) {
                return match
            }
        }
        return nil
    }

    /// A name a person can act on. "pid 355" tells nobody anything, so an unmatched
    /// assertion falls back to the process name the system reported with it.
    private func displayName(
        for assertion: SleepAssertionCollector.Assertion,
        member: ProcessIntervalMetrics?
    ) -> String {
        if let member {
            return member.identity.groupDisplayName
        }
        return "System process (pid \(assertion.pid))"
    }

    private func verdict(isSystem: Bool, displayAsleep: Bool) -> String {
        if isSystem { return "Ignored: this is a system process." }
        if !displayAsleep { return "Ignored while the display is on." }
        return "Would be reported after five minutes."
    }
}
