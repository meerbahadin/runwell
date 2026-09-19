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
        // `Window` rather than `WindowGroup`, as Tidely uses. A WindowGroup with no
        // title set leaves macOS showing the app name in its own reserved band at
        // the top of the content column — a strip that starts at the sidebar's
        // trailing edge instead of spanning the window, so it reads as offset. A
        // single titled Window also matches what this app is: there is one main
        // surface, and opening a second copy of it was never meaningful.
        Window("Runwell", id: Self.mainWindowID) {
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
                    // A sheet paints its own opaque surface, which showed as a flat
                    // white slab behind the card. Tidely shows onboarding inline in
                    // the window, so the card floats on the window's own material;
                    // using that material here gives the same result while keeping
                    // the sheet's behaviour.
                    .presentationBackground(.regularMaterial)
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
                .background(FullHeightSidebar())
        }
        // Deliberately no `.windowToolbarStyle(.unified)`. The unified style paints
        // its own flat toolbar surface, which replaces the standard window material
        // — the material is what produces the translucent "liquid glass" look on
        // macOS 26 and later. With it set, the sidebar and toolbar render opaque.
        // The default style keeps the material, and the views below avoid painting
        // over it.
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
    /// Owned here rather than inside the view, because the uninstall list and its
    /// detail pane are two separate columns of the split view and must agree on
    /// what is selected.
    @State private var uninstallModel = UninstallModel()

    /// Section 8.1 information architecture.
    enum Surface: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case applications = "Applications"
        case history = "History"
        case uninstall = "Uninstall"
        case diagnostics = "Diagnostics"
        case settings = "Settings"
        var id: String { rawValue }

        /// Filled glyphs of an even visual weight, as in Tidely. The previous set
        /// mixed a detailed outline gauge with flat line symbols, so the sidebar
        /// read as unevenly weighted rather than as one set.
        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .applications: "square.stack.3d.up"
            case .history: "clock.arrow.circlepath"
            case .uninstall: "trash"
            case .diagnostics: "waveform.path.ecg"
            case .settings: "gearshape"
            }
        }
    }

    private var surfaceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, Theme.Spacing.lg)
                // The sidebar now runs under the titlebar, so the wordmark has to
                // clear the traffic lights rather than sitting beneath a strip that
                // was reserving that space for it.
                .padding(.top, Theme.Spacing.xxxl)
                .padding(.bottom, Theme.Spacing.lg)

            List(Surface.allCases, selection: $selection) { surface in
                Label(surface.rawValue, systemImage: surface.symbol)
                    .tag(surface)
            }
            // The sidebar style is what renders selection as the translucent
            // capsule over the window material rather than a flat filled
            // rectangle; hiding the scroll background stops the list painting
            // over that material.
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        // No background: a sidebar inside NavigationSplitView already gets the
        // system's translucent material. Painting over it produces the flat,
        // opaque look and loses the vibrancy behind the selection highlight.
        .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
    }

    /// Wordmark only: the icon is already in the Dock and the title bar, and a third
    /// copy of it in the sidebar competed with the section glyphs below rather than
    /// anchoring them.
    private var brand: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Runwell").font(Theme.Typography.headline)
            Text("Honest battery monitoring")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.faintText)
        }
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
            // Tidely uses the balanced style: the sidebar keeps the window's own
            // material instead of the prominent style's opaque panel, which is what
            // leaves a hard seam between an opaque sidebar and white content.
            .navigationSplitViewStyle(.balanced)
        case .uninstall:
            // Same three-column shape as Applications: a list of things on the left
            // and what is selected on the right. Putting this in the two-column case
            // instead left the split view sizing itself to its content, which is
            // what floated the list in the middle of an empty pane.
            NavigationSplitView {
                surfaceList
            } content: {
                UninstallListView(model: uninstallModel)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } detail: {
                UninstallDetailView(model: uninstallModel)
            }
            .navigationSplitViewStyle(.balanced)
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

/// Lets the sidebar's material run the full height of the window, including behind
/// the titlebar.
///
/// SwiftUI otherwise reserves an opaque titlebar strip across the content column
/// only — it begins at the sidebar's trailing edge rather than at the window's, so
/// it reads as a band shifted to the right, with the traffic lights stranded above
/// the sidebar in a differently-coloured area. Hiding the title text and making the
/// titlebar transparent lets the split view own the whole window, which is how the
/// full-height sidebar look is actually produced.
private struct FullHeightSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The window is nil on the first pass and can change if the view is
        // re-hosted, so this re-applies rather than assuming makeNSView caught it.
        configure(view.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window, window.isRunwellMainWindow else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Keep the titlebar itself: removing it (`.fullSizeContentView` alone, or
        // `.hiddenTitleBar`) also removes the standard window material, which is
        // what produces the translucency in the first place.
        window.styleMask.insert(.fullSizeContentView)
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
                    // another one. `Window` is single-instance so this can no longer
                    // produce duplicates, but reopening a closed window and raising
                    // an open one are still different operations.
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
