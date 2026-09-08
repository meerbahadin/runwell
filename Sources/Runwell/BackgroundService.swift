import Foundation
import AppKit
import ServiceManagement
import RunwellKit

/// Section 5.1 / 10.2. Keeps Runwell recording when nobody is looking at it, at a
/// cadence chosen for the current power state.
///
/// This is what makes history representative: a battery drains while the lid is shut
/// and the window is closed, so a monitor that only samples with its window open
/// records exactly the periods the user cares least about.
@MainActor
@Observable
final class BackgroundService {
    private weak var environment: AppEnvironment?
    private var observers: [NSObjectProtocol] = []

    /// Section 1.3: the monitor must not become a meaningful source of drain, so
    /// running in the background is opt-in and states its cost.
    var runsInBackground: Bool {
        didSet {
            UserDefaults.standard.set(runsInBackground, forKey: "runsInBackground")
            applyActivationPolicy()
            updateMode()
        }
    }

    /// Registered with the system rather than written into a login-items plist, which
    /// is the supported route on macOS 13+ and appears in System Settings where the
    /// user can revoke it.
    var launchesAtLogin: Bool {
        didSet {
            guard launchesAtLogin != oldValue else { return }
            do {
                if launchesAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
                launchesAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private(set) var loginItemError: String?

    /// True while the main window is closed and only the menu bar remains.
    private(set) var isWindowVisible = true

    init(environment: AppEnvironment) {
        self.environment = environment
        self.runsInBackground = UserDefaults.standard.object(forKey: "runsInBackground") as? Bool ?? true
        self.launchesAtLogin = SMAppService.mainApp.status == .enabled
        observePowerState()
        updateMode()
    }

    /// Observers are removed explicitly rather than in deinit, which cannot touch
    /// main-actor state under strict concurrency.
    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - Power state

    private func observePowerState() {
        let workspace = NSWorkspace.shared.notificationCenter

        // Section 7.3: sleep and wake are session boundaries, so deltas are never
        // bridged across them.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.environment?.handlePowerSourceChange() }
        })

        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.environment?.handlePowerSourceChange()
                self?.updateMode()
            }
        })

        // Window visibility, observed on AppKit rather than SwiftUI's onDisappear:
        // a WindowGroup scene does not reliably deliver onDisappear when the user
        // closes the window, which left the sampler at the 2-second foreground
        // cadence with nothing on screen to justify it.
        let centre = NotificationCenter.default
        observers.append(centre.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // `notification` is read here, synchronously, in the outer closure —
            // not forwarded into an isolated context — since Notification is not
            // Sendable and strict concurrency correctly refuses to let it cross an
            // actor boundary. `.object` alone touches nothing AppKit-isolated;
            // only the `.contentView` read below needs the main-actor guarantee
            // `queue: .main` provides at runtime but the closure's own @Sendable
            // type does not statically carry.
            guard let closing = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                // A window that is closing has already resigned key and main
                // status, so it cannot be identified that way. Instead check what
                // remains: once the last real window goes, only panels and the
                // menu-bar extra are left.
                guard closing.contentView != nil else { return }
                Task { @MainActor in
                    // Give AppKit a turn to finish removing it from the window list.
                    try? await Task.sleep(for: .milliseconds(120))
                    let remaining = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
                    if remaining.isEmpty { self?.windowBecameHidden() }
                }
            }
        })

        observers.append(centre.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windowBecameVisible() }
        })

        // Low Power Mode: Section 5.1 drops to the slowest cadence automatically,
        // because a user who has asked macOS to save power has already told us what
        // they want.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateMode() }
        })
    }

    // MARK: - Window visibility

    func windowBecameVisible() {
        isWindowVisible = true
        updateMode()
        applyActivationPolicy()
    }

    func windowBecameHidden() {
        isWindowVisible = false
        updateMode()
        // The Dock tile goes with the window: a tile implies something to click back
        // to, and once Runwell is only recording, the menu bar is the honest place
        // for it. Reopening from the menu bar brings the tile back.
        applyActivationPolicy()
    }

    /// Section 5.1's cadence table, applied automatically. Each step down is a real
    /// reduction in observer effect, which is why the app does not simply sample at
    /// two seconds forever.
    private func updateMode() {
        guard let environment else { return }

        let mode: SamplingMode
        // Section 5.1 / Settings' own promise: "Recording stops when you close the
        // window." Previously this method never checked runsInBackground at all, so
        // turning the toggle off only ever changed *how often* Runwell sampled —
        // never whether it did. The window being open always overrides this: a
        // visible window means the user is looking at live numbers right now,
        // independent of what happens once they close it.
        if !runsInBackground && !isWindowVisible {
            mode = .paused
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
            mode = .lowPowerMode
        } else if isWindowVisible {
            mode = .foreground
        } else if environment.snapshot?.battery.powerSource == .battery {
            // Window closed and running on battery: the case where the observer effect
            // matters most, so it takes the slowest routine cadence.
            mode = .batteryIdle
        } else {
            mode = .menuBarOnly
        }
        environment.setMode(mode)
    }

    /// With no visible window an accessory app keeps no Dock tile, so Runwell sits
    /// in the menu bar rather than looking like a window the user failed to close.
    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(runsInBackground && !isWindowVisible ? .accessory : .regular)
    }

    /// A plain description of the current cost, for Settings.
    var statusDescription: String {
        if !runsInBackground {
            return "Recording stops when you close the window."
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return "Low Power Mode: checking every 15 seconds to save battery."
        }
        return isWindowVisible
            ? "Checking every 2 seconds while the window is open."
            : "Running in the menu bar, checking less often to save battery."
    }
}
