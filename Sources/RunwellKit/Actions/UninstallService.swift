import Foundation
import AppKit

/// Finding and removing installed applications, together with the support files
/// they leave behind.
///
/// Two principles carry over from the rest of the app. Removal goes to the Trash,
/// never to `unlink`: the Trash is the undo, and an uninstaller without one is a
/// single misclick away from losing something unrecoverable. And what is reported
/// is only ever what was actually found — a support file this cannot prove belongs
/// to the app is not listed, because the cost of a wrong guess here is deleting a
/// different application's data (Appendix F applied to deletion: do not claim what
/// you cannot establish).
public struct UninstallService: Sendable {
    public init() {}

    public enum UninstallError: LocalizedError, Equatable {
        case protected(String)
        case running(String)
        case notRemovable(String)

        public var errorDescription: String? {
            switch self {
            case .protected(let reason): reason
            case .running(let name):
                "\(name) is still running. Quit it before uninstalling."
            case .notRemovable(let reason): reason
            }
        }
    }

    /// One removable item: the bundle itself, or a support file beside it.
    public struct Residue: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case bundle
            case caches
            case preferences
            case containers
            case applicationSupport
            case savedState
            case logs

            public var label: String {
                switch self {
                case .bundle: "Application"
                case .caches: "Caches"
                case .preferences: "Preferences"
                case .containers: "Container"
                case .applicationSupport: "Application Support"
                case .savedState: "Saved state"
                case .logs: "Logs"
                }
            }
        }

        public var id: URL { url }
        public let url: URL
        public let kind: Kind
        /// Bytes on disk, or nil when the size could not be measured. Never 0 as a
        /// stand-in for "unknown" — Section 3 / Appendix F.
        public let sizeBytes: Int64?

        public init(url: URL, kind: Kind, sizeBytes: Int64?) {
            self.url = url
            self.kind = kind
            self.sizeBytes = sizeBytes
        }
    }

    /// An installed application Runwell is willing to offer to uninstall.
    public struct InstalledApp: Sendable, Equatable, Identifiable {
        public var id: URL { bundleURL }
        public let bundleURL: URL
        public let name: String
        public let bundleID: String?
        public let sizeBytes: Int64?
        /// True while any process from this bundle is running: uninstalling would
        /// pull the executable out from under it.
        public let isRunning: Bool

        public init(
            bundleURL: URL, name: String, bundleID: String?,
            sizeBytes: Int64?, isRunning: Bool
        ) {
            self.bundleURL = bundleURL
            self.name = name
            self.bundleID = bundleID
            self.sizeBytes = sizeBytes
            self.isRunning = isRunning
        }
    }

    // MARK: - Policy

    /// Locations whose contents are managed by macOS or by the App Store and must
    /// never be moved from here. `/System/Applications` is where Apple's own apps
    /// live and is on a sealed, read-only volume in any case.
    static let protectedPrefixes = [
        "/System/", "/Library/Apple/", "/usr/", "/bin/", "/sbin/", "/private/var/",
    ]

    /// The directories a user actually installs into. Anything outside these is not
    /// offered: a bundle found elsewhere is as likely to be inside a disk image, a
    /// downloads folder or another app's resources as it is to be an installation.
    public static func searchDirectories() -> [URL] {
        var directories = [URL(fileURLWithPath: "/Applications")]
        if let home = FileManager.default.homeDirectoryForCurrentUser as URL? {
            directories.append(home.appendingPathComponent("Applications", isDirectory: true))
        }
        return directories
    }

    /// Whether this bundle may be offered for uninstall at all.
    public func evaluate(bundleURL: URL) -> UninstallError? {
        let path = bundleURL.standardizedFileURL.path
        for prefix in Self.protectedPrefixes where path.hasPrefix(prefix) {
            return .protected(
                "\(bundleURL.lastPathComponent) is part of macOS and cannot be removed here.")
        }
        // Runwell must not offer to uninstall Runwell: it would be deleting the
        // executable currently running this code.
        if path == Bundle.main.bundleURL.standardizedFileURL.path {
            return .protected("This is Runwell itself.")
        }
        guard FileManager.default.isWritableFile(atPath: path) else {
            return .notRemovable(
                "\(bundleURL.lastPathComponent) is not writable by your account.")
        }
        return nil
    }

    // MARK: - Discovery

    /// Every user-installed application, newest listing first by name.
    public func installedApplications() -> [InstalledApp] {
        let manager = FileManager.default
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap {
                $0.bundleURL?.standardizedFileURL.path
            }
        )

        var apps: [InstalledApp] = []
        for directory in Self.searchDirectories() {
            let contents = (try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in contents where url.pathExtension == "app" {
                guard evaluate(bundleURL: url) == nil else { continue }
                let bundle = Bundle(url: url)
                let name = bundle?.infoDictionary?["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(
                    bundleURL: url,
                    name: name,
                    bundleID: bundle?.bundleIdentifier,
                    sizeBytes: directorySize(of: url),
                    isRunning: running.contains(url.standardizedFileURL.path)
                ))
            }
        }
        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Support files belonging to `app`, including the bundle itself as the first
    /// entry.
    ///
    /// Matching is by bundle identifier only. A name-based search would catch
    /// unrelated files — an app called "Mail" would match half of `~/Library` — and
    /// this is code that deletes things, so it errs entirely toward missing a
    /// leftover rather than removing something it does not own.
    public func residue(for app: InstalledApp) -> [Residue] {
        var items = [Residue(url: app.bundleURL, kind: .bundle, sizeBytes: app.sizeBytes)]
        guard let bundleID = app.bundleID, !bundleID.isEmpty else { return items }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)

        // Each candidate is an exact path built from the bundle identifier, never a
        // prefix scan: `com.example.app` must not match `com.example.apple`.
        let candidates: [(String, Residue.Kind)] = [
            ("Caches/\(bundleID)", .caches),
            ("Preferences/\(bundleID).plist", .preferences),
            ("Containers/\(bundleID)", .containers),
            ("Application Support/\(bundleID)", .applicationSupport),
            ("Saved Application State/\(bundleID).savedState", .savedState),
            ("Logs/\(bundleID)", .logs),
        ]

        for (relative, kind) in candidates {
            let url = library.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            items.append(Residue(url: url, kind: kind, sizeBytes: directorySize(of: url)))
        }
        return items
    }

    // MARK: - Removal

    /// What a removal actually did, per item, so the UI can report the truth rather
    /// than a blanket "uninstalled".
    public struct Outcome: Sendable, Equatable {
        public struct Failure: Sendable, Equatable {
            public let url: URL
            public let reason: String
        }
        public let trashed: [URL]
        public let failed: [Failure]

        public var isCompleteSuccess: Bool { failed.isEmpty }
    }

    /// Moves `items` to the Trash. Requires the app not to be running, and requires
    /// the caller to have confirmed: this is destructive from the user's point of
    /// view even though it is recoverable.
    @MainActor
    public func uninstall(
        app: InstalledApp, items: [Residue], userConfirmed: Bool
    ) -> Result<Outcome, UninstallError> {
        guard userConfirmed else {
            return .failure(.notRemovable("Uninstalling requires confirmation."))
        }
        if let error = evaluate(bundleURL: app.bundleURL) { return .failure(error) }
        // Re-check rather than trusting the flag captured at listing time: the user
        // may have launched the app in between, and trashing a running app's bundle
        // leaves it in a half-broken state.
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.standardizedFileURL == app.bundleURL.standardizedFileURL
        }) {
            return .failure(.running(app.name))
        }

        var trashed: [URL] = []
        var failed: [Outcome.Failure] = []
        for item in items {
            // Every item is re-checked: `residue` may have been computed a while ago
            // and a path outside the protected set then is not guaranteed to be one
            // now.
            if item.kind == .bundle, let error = evaluate(bundleURL: item.url) {
                failed.append(.init(url: item.url, reason: error.localizedDescription))
                continue
            }
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                trashed.append(item.url)
            } catch {
                failed.append(.init(url: item.url, reason: error.localizedDescription))
            }
        }
        return .success(Outcome(trashed: trashed, failed: failed))
    }

    // MARK: - Sizing

    /// Total bytes on disk, or nil when it could not be established. Uses allocated
    /// size rather than logical size, since that is what removing it gives back.
    func directorySize(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return nil
        }
        if values.isRegularFile == true {
            return (try? url.resourceValues(forKeys: keys))
                .flatMap { $0.totalFileAllocatedSize.map(Int64.init) }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true }
        ) else { return nil }

        var total: Int64 = 0
        var sawAnything = false
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys) else { continue }
            if let bytes = childValues.totalFileAllocatedSize {
                total += Int64(bytes)
                sawAnything = true
            }
        }
        // An enumeration that read nothing at all means the size is unknown, which
        // is not the same as an empty directory.
        return sawAnything ? total : nil
    }
}
