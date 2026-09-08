import SwiftUI
import PowerTaskKit
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
    let actions = ProcessActionService()

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
    }

    func stop() {
        runTask?.cancel()
        observeTask?.cancel()
        runTask = nil
        observeTask = nil
    }

    private func apply(_ snapshot: SamplerSnapshot) {
        self.snapshot = snapshot
    }

    /// Section 7.3: a power-source transition is a session boundary, so deltas are
    /// not bridged across it.
    func handlePowerSourceChange() {
        Task { await sampler.beginNewSession() }
    }

    func setMode(_ mode: SamplingMode) {
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
