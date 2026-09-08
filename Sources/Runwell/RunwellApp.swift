import SwiftUI
import PowerTaskKit

/// Section 4.1. UI lifecycle and navigation.
@main
struct PowerTaskApp: App {
    @State private var environment = AppEnvironment()
    @State private var background: BackgroundService?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    environment.start()
                    if background == nil {
                        background = BackgroundService(environment: environment)
                        environment.background = background
                    }
                    background?.windowBecameVisible()
                }
                // Section 5.1: closing the window drops the sampling cadence rather
                // than stopping history, so a closed lid still records.
                .onDisappear { background?.windowBecameHidden() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Section 5.1: the menu-bar surface samples less often than the main window.
        MenuBarExtra("PowerTask", systemImage: "bolt.fill") {
            MenuBarContent()
                .environment(environment)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection: Surface = .overview

    /// Section 8.1 information architecture.
    enum Surface: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case applications = "Applications"
        case history = "History"
        case diagnostics = "Diagnostics"
        case settings = "Settings"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.bottom.50percent"
            case .applications: "list.bullet.rectangle"
            case .history: "chart.xyaxis.line"
            case .diagnostics: "stethoscope"
            case .settings: "gearshape"
            }
        }
    }

    private var surfaceList: some View {
        List(Surface.allCases, selection: $selection) { surface in
            Label(surface.rawValue, systemImage: surface.symbol)
                .tag(surface)
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
    }

    var body: some View {
        @Bindable var environment = environment

        // Each surface picks its own column count, rather than one split view trying
        // to serve both. Nesting a NavigationSplitView inside another's detail pane
        // made AppKit reserve an extra column, which is what left the dead gutter
        // beside the detail content and squeezed the application table to a sliver.
        switch selection {
        case .overview, .history, .diagnostics, .settings:
            // These surfaces have no per-row detail, so each takes the full width
            // beside the sidebar instead of stranding an empty third column.
            NavigationSplitView {
                surfaceList
            } detail: {
                switch selection {
                case .history: HistoryView()
                case .diagnostics: DiagnosticsView()
                case .settings: SettingsView()
                default: OverviewView()
                }
            }
        case .applications:
            NavigationSplitView {
                surfaceList
            } content: {
                ApplicationsView()
                    .navigationSplitViewColumnWidth(min: 520, ideal: 680)
            } detail: {
                if let group = environment.selectedGroup {
                    ProcessDetailView(group: group)
                } else {
                    ContentUnavailableView(
                        "Select an application",
                        systemImage: "hand.point.up.left",
                        description: Text("Choose an application to see its processes, provenance and actions.")
                    )
                }
            }
        }
    }
}

/// Section 5.1 / 8.1. A compact live summary in the menu bar.
struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let battery = environment.snapshot?.battery, battery.isPresent {
                HStack {
                    Text(battery.percentage.formatted("%.0f", suffix: "%"))
                        .font(.title3.weight(.medium)).monospacedDigit()
                    Text(battery.isCharged ? "Charged"
                         : battery.isCharging ? "Charging"
                         : battery.powerSource == .wallPower ? "On power" : "On battery")
                        .foregroundStyle(.secondary)
                }
            }

            // Section 8.3: if something is worth saying, the menu bar says it first.
            if let insight = environment.insights.first {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: insight.rule.symbolName)
                        .foregroundStyle(insight.severity == .warning ? .orange : .secondary)
                    Text(insight.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            Text("Top energy users").font(.caption).foregroundStyle(.secondary)

            if environment.isWaitingForFirstInterval {
                Text("Measuring…").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(environment.groups.prefix(5)) { group in
                    HStack(spacing: 8) {
                        AppIcon(bundleURL: group.bundleURL, size: 14)
                        Text(group.displayName).lineLimit(1)
                        Spacer()
                        MetricText(metric: group.totalEnergyWatts, format: "%.2f", suffix: " W")
                    }
                    .font(.callout)
                }
            }

            Divider()
            Button("Quit PowerTask") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.callout)
        }
        .padding(12)
        .frame(width: 280)
    }
}
