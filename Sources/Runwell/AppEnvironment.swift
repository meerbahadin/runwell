import SwiftUI
import AppKit
import RunwellKit
import Observation

/// Section 4.1. Owns the sampler and publishes immutable snapshots to the UI.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var snapshot: SamplerSnapshot?
    private(set) var capabilities: CapabilitySet
    private(set) var lastError: String?

    /// Section 8.2: values must not reorder continuously while the pointer is over
    /// the table, so sorting is frozen while the user is interacting with it.
    var sortOrder: SortColumn = .energy {
        didSet { if sortOrder != oldValue { frozenOrder = nil } }
    }
    var isPointerOverTable = false {
        didSet {
            if !isPointerOverTable { frozenOrder = nil }
        }
    }
    var searchText = ""
    var selectedGroupID: ApplicationGroupID?
    var normalizeCPU = false {
        didSet { Task { await sampler.setNormalizeCPU(normalizeCPU) } }
    }

    private var frozenOrder: [ApplicationGroupID]?
    private let sampler: SamplerService
    private var runTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    let actions = ProcessActionService()

    /// Set once the scene exists; owns background cadence and login-item state.
    var background: BackgroundService?

    // MARK: - Insights

    private let insightEngine: InsightEngine
    private var insightState = InsightEngine.State()
    private(set) var insights: [Insight] = []

    /// The application an insight is about, when it is still running. An insight can
    /// outlive the process it names — a stored episode is history, not a live thing —
    /// so this is optional by design.
    func group(for insight: Insight) -> ApplicationGroup? {
        groups.first { $0.id == insight.appGroupID }
    }

    /// Section 8.4 "Ignore alerts": muting stops the alert, never the measurement.
    func mute(_ insight: Insight) {
        insightState.mute(insight)
        insights = insightState.activeInsights
    }

    /// Off by default. An unexpected banner from a battery monitor reads as noise,
    /// and Section 1.3's restraint applies to interruptions as much as to sampling:
    /// the insights are always visible in the app, so notifying is opt-in.
    var areNotificationsEnabled = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(areNotificationsEnabled, forKey: "notifications")
            // Ask when the user opts in, not when an insight happens to fire. Tying
            // the prompt to the first insight meant a dialog the user missed left
            // notifications permanently silent: the same condition stays raised, so
            // there is no second transition to ask again on.
            if areNotificationsEnabled {
                NotificationService.shared.requestAuthorizationIfNeeded()
            }
        }
    }

    // MARK: - History

    private(set) var history: HistoryStore?
    private(set) var historyURL: URL?
    private(set) var historyError: String?

    /// Section 7.2 / 9.1: history can be disabled entirely while live monitoring
    /// continues. Persisted so the choice survives a relaunch.
    /// Whether the first-run introduction has been completed. Defaults to false so
    /// a fresh install sees it; existing installs upgrading into this version see it
    /// once too, which is the right call — the measurement model was never explained
    /// to them either.
    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    var isHistoryEnabled = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isHistoryEnabled, forKey: "historyEnabled")
            if isHistoryEnabled { openHistory() } else { history = nil }
        }
    }

    enum SortColumn: String, CaseIterable, Identifiable {
        case energy = "Energy"
        case cpu = "CPU"
        case memory = "Memory"
        case name = "Name"
        var id: String { rawValue }
    }

    init() {
        let capabilities = CapabilityProbe().probe()
        self.capabilities = capabilities
        self.sampler = SamplerService(capabilities: capabilities)
        // Section 8.3: thresholds are calibrated to this Mac rather than fixed.
        self.insightEngine = InsightEngine(thresholds: .calibrated(for: capabilities))
        if isHistoryEnabled { openHistory() }
        // Settle authorization at construction, not in the window's .task: with
        // background recording on, Runwell can launch straight into the menu bar
        // with no window, and an authorization request that never ran meant every
        // banner was silently dropped for the whole session.
        if areNotificationsEnabled {
            NotificationService.shared.requestAuthorizationIfNeeded()
        }
    }

    private func openHistory() {
        do {
            let url = try HistoryStore.defaultURL()
            historyURL = url
            history = try HistoryStore(url: url)
            historyError = nil
        } catch {
            // Section 10.2: a failing subsystem is disabled independently with a
            // visible reason rather than taking live monitoring down with it.
            history = nil
            historyError = error.localizedDescription
        }
    }

    func start() {
        guard runTask == nil else { return }
        let sampler = self.sampler
        observeTask = Task { [weak self] in
            for await snapshot in sampler.snapshots {
                guard let self else { return }
                await MainActor.run { self.apply(snapshot) }
            }
        }
        runTask = Task {
            // Section 4.2: a monotonic scheduler drives collection; the first cycle
            // only establishes a baseline, since every rate needs two samples.
            await sampler.run()
        }
        startPruning()
    }

    func stop() {
        runTask?.cancel()
        observeTask?.cancel()
        pruneTask?.cancel()
        runTask = nil
        observeTask = nil
        pruneTask = nil
    }

    private func apply(_ snapshot: SamplerSnapshot) {
        self.snapshot = snapshot
        evaluateInsights(snapshot)
        // Section 7.2: persistence happens off the main actor, so the UI is never
        // waiting on a disk write.
        if let history {
            Task.detached(priority: .utility) {
                do { try await history.record(snapshot) }
                catch { await MainActor.run { self.historyError = error.localizedDescription } }
            }
        }
    }

    /// Section 4.2: insight rules are evaluated after each cycle's view model is
    /// published, and alerts fire only on the transition into a condition.
    private func evaluateInsights(_ snapshot: SamplerSnapshot) {
        // An app the user is looking at is not "background activity", so the rule
        // needs to know which groups are frontmost right now.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var foreground: Set<ApplicationGroupID> = []
        if let frontmost {
            for group in snapshot.groups where group.members.contains(where: { $0.key.pid == frontmost }) {
                foreground.insert(group.id)
            }
        }

        let newlyRaised = insightEngine.evaluate(
            snapshot: snapshot, foregroundGroupIDs: foreground, state: &insightState
        )
        insights = insightState.activeInsights

        // Section 7.1: persist the episode so it outlives the live view. Gated on
        // the history setting like every other recording — an insight log is a
        // record of when the Mac was used and for what.
        if isHistoryEnabled, let history {
            let live = Set(insightState.activeInsights.map(\.id))
            let raised = newlyRaised
            Task {
                try? await history.recordInsightsRaised(raised)
                try? await history.closeInsights(stillOpen: live)
            }
        }

        if areNotificationsEnabled {
            // Called every cycle, not only on a transition: insights held back by a
            // spacing window have no second transition to arrive on, so the service
            // needs a tick to release them.
            NotificationService.shared.post(newlyRaised)
        }
    }

    /// Section 7.2: retention runs on a slow cadence, not on every sample.
    private func startPruning() {
        guard pruneTask == nil else { return }
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                if let history = await self?.history {
                    try? await history.prune()
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func clearHistory() async {
        guard let history else { return }
        do { try await history.deleteAllHistory() }
        catch { historyError = error.localizedDescription }
    }

    func historyStatistics() async -> HistoryStore.Statistics? {
        guard let history, let historyURL else { return nil }
        return try? await history.statistics(url: historyURL)
    }

    /// Section 7.3: a power-source transition is a session boundary, so deltas are
    /// not bridged across it.
    func handlePowerSourceChange() {
        Task { await sampler.beginNewSession() }
    }

    /// Mirrors the sampler's mode for the Settings picker. The sampler stays the
    /// source of truth; this is a UI-side reflection updated when the user changes it.
    private(set) var samplingMode: SamplingMode = .foreground

    func setMode(_ mode: SamplingMode) {
        samplingMode = mode
        Task { await sampler.setMode(mode) }
    }

    // MARK: - Derived view state

    var groups: [ApplicationGroup] {
        guard let snapshot else { return [] }
        var result = snapshot.groups

        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Section 8.2: hold the previous order while the pointer is over the table so
        // rows do not swap under the cursor mid-click.
        if isPointerOverTable, let frozen = frozenOrder {
            let position = Dictionary(uniqueKeysWithValues: frozen.enumerated().map { ($1, $0) })
            result.sort { a, b in
                switch (position[a.id], position[b.id]) {
                case let (x?, y?): x < y
                case (nil, _): false   // new rows sort to the bottom until the freeze lifts
                case (_, nil): true
                }
            }
            return result
        }

        result.sort(by: Self.comparator(for: sortOrder))
        if isPointerOverTable, frozenOrder == nil {
            frozenOrder = result.map(\.id)
        }
        return result
    }

    private static func comparator(for column: SortColumn) -> (ApplicationGroup, ApplicationGroup) -> Bool {
        switch column {
        case .energy:
            // Unavailable values sort last rather than as zero.
            return { ($0.totalEnergyWatts.value ?? -1) > ($1.totalEnergyWatts.value ?? -1) }
        case .cpu:
            return { ($0.totalCPUPercent.value ?? -1) > ($1.totalCPUPercent.value ?? -1) }
        case .memory:
            return { ($0.totalFootprintBytes.value ?? 0) > ($1.totalFootprintBytes.value ?? 0) }
        case .name:
            return { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    var selectedGroup: ApplicationGroup? {
        guard let id = selectedGroupID else { return nil }
        return snapshot?.groups.first { $0.id == id }
    }

    /// Section 1.4: the dominant measured energy consumer, identifiable at a glance.
    var topEnergyGroup: ApplicationGroup? {
        snapshot?.groups
            .filter { ($0.totalEnergyWatts.value ?? 0) > 0 }
            .max { ($0.totalEnergyWatts.value ?? 0) < ($1.totalEnergyWatts.value ?? 0) }
    }

    var isWaitingForFirstInterval: Bool {
        snapshot == nil || (snapshot?.groups.isEmpty ?? true)
    }
}
