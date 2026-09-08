import SwiftUI
import RunwellKit

/// Section 4.1. UI lifecycle and navigation.
@main
struct RunwellApp: App {
    @State private var environment = AppEnvironment()
    @State private var background: BackgroundService?

    private var hasWarning: Bool {
        environment.insights.contains { $0.severity == .warning }
    }

    /// Named so the menu bar can reopen the window after it has been closed.
    static let mainWindowID = "runwell.main"

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environment(environment)
                .frame(minWidth: 820, minHeight: 520)
                // A sheet rather than a separate window: collection starts
                // underneath, so by the time the introduction is dismissed the first
                // interval has already elapsed and the app is not empty.
                .sheet(isPresented: Binding(
                    get: { !environment.hasCompletedOnboarding },
                    set: { if !$0 { environment.hasCompletedOnboarding = true } }
                )) {
                    OnboardingView(capabilities: environment.capabilities) {
                        environment.hasCompletedOnboarding = true
                    }
                    // The introduction explains the app; dismissing it by clicking
                    // away would skip that, so it is finished with the button.
                    .interactiveDismissDisabled()
                }
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
        // The symbol reflects state rather than being a fixed bolt: the menu bar is
        // the only surface visible when the window is closed, so it should say
        // whether the Mac is charging, running low, or has something worth reading.
        MenuBarExtra {
            MenuBarContent()
                .environment(environment)
        } label: {
            MenuBarLabel(hasWarning: hasWarning)
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
/// The menu-bar label: Runwell's own mark rather than a generic bolt.
///
/// Loaded as a template image so macOS inverts it for dark mode and for the
/// highlighted state; a colour image would stay dark on a dark menu bar. Falls back
/// to the bolt if the asset is missing from the bundle for any reason.
struct MenuBarLabel: View {
    let hasWarning: Bool

    var body: some View {
        if let icon = NSImage(named: "MenuBarIcon") {
            // The template flag is what lets AppKit recolour it per state.
            let template: NSImage = {
                let copy = icon.copy() as! NSImage
                copy.isTemplate = true
                return copy
            }()
            Image(nsImage: template)
                // Section 8.5: a raised warning is not conveyed by the mark alone —
                // the menu's first line still states it in words.
                .overlay(alignment: .topTrailing) {
                    if hasWarning {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -1)
                    }
                }
        } else {
            Image(systemName: hasWarning ? "bolt.trianglebadge.exclamationmark" : "bolt.fill")
        }
    }
}

extension NSWindow {
    /// The app's real window, as opposed to the menu-bar extra's panel or any
    /// system-owned window that happens to belong to the process.
    var isRunwellMainWindow: Bool {
        // Menu-bar extras and popovers are panels; the document window is not.
        !(self is NSPanel) && contentViewController != nil && canBecomeMain
    }
}

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var environment

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row + 2) {
            if let battery = environment.snapshot?.battery, battery.isPresent {
                HStack(spacing: Theme.Spacing.row) {
                    // Section 8.5: the icon carries state, the text states it too.
                    Image(systemName: batterySymbol(battery))
                        .font(.title3)
                        .foregroundStyle(batteryTint(battery))
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(battery.percentage.formatted("%.0f", suffix: "%"))
                            .font(.title3.weight(.medium)).monospacedDigit()
                        Text(batteryStatusText(battery))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            // Section 8.3: if something is worth saying, the menu bar says it first.
            if let insight = environment.insights.first {
                Divider()
                HStack(alignment: .top, spacing: Theme.Spacing.row - 2) {
                    Image(systemName: insight.rule.symbolName)
                        .foregroundStyle(insight.severity == .warning ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(insight.message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        // The evidence travels with the claim here too, so the menu
                        // never asserts something the window would have justified.
                        Text(insight.evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            HStack {
                Button("Open Runwell") {
                    // Bring the app forward as a regular app: it may be running as a
                    // menu-bar accessory with no window and no Dock tile, in which
                    // case activating alone would surface nothing.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    // Raise the window that already exists rather than asking for
                    // another one: WindowGroup will happily open a second, third and
                    // fourth copy, and pressing the menu item twice should not.
                    if let existing = NSApp.windows.first(where: \.isRunwellMainWindow) {
                        existing.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: RunwellApp.mainWindowID)
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.card)
        .frame(width: 290)
    }

    private func batterySymbol(_ battery: BatterySnapshot) -> String {
        if battery.isCharging || battery.isCharged { return "battery.100percent.bolt" }
        guard let percent = battery.percentage.value else { return "battery.50percent" }
        switch percent {
        case ..<11: return "battery.0percent"
        case ..<26: return "battery.25percent"
        case ..<60: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }

    /// Colour is a reinforcement here, never the message: the status line beside it
    /// always says the same thing in words (Section 8.5).
    private func batteryTint(_ battery: BatterySnapshot) -> Color {
        if battery.isCharging || battery.isCharged { return .green }
        guard let percent = battery.percentage.value else { return .secondary }
        if percent <= 10 { return .red }
        if percent <= 20 { return .orange }
        return .primary
    }

    private func batteryStatusText(_ battery: BatterySnapshot) -> String {
        if battery.isCharged { return "Charged" }
        if battery.isCharging { return "Charging" }
        if battery.powerSource == .wallPower { return "On power" }
        if let percent = battery.percentage.value, percent <= 20 {
            return percent <= 10 ? "On battery — very low" : "On battery — low"
        }
        return "On battery"
    }
}
