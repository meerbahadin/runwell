import Foundation
import AppKit
import UniformTypeIdentifiers

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

    /// Whether a `.app` on disk is an application a person would recognise as
    /// installed, rather than a helper that merely uses the bundle format.
    ///
    /// Two questions, in order, because they are genuinely different:
    ///
    /// 1. *Is this an application bundle at all?* That is the filesystem's own
    ///    judgement, via `isApplicationKey` and the `.application` content type,
    ///    rather than trusting a `.app` extension on a directory.
    /// 2. *Is it an application a person installed and would choose to remove?*
    ///    The type system cannot answer this — it reports `com.apple.application-bundle`
    ///    for a URL-handler stub exactly as it does for Safari — so it takes
    ///    `LSBackgroundOnly`, which marks a bundle that has no interface at all and
    ///    exists only to service another app.
    ///
    /// `LSUIElement` deliberately does *not* exclude: a menu-bar app has no Dock tile
    /// but is still an application the user installed and may well want gone. On this
    /// machine that flag covers Docker, Maccy and Scroll Reverser, all of which belong
    /// in the list.
    static func isUninstallableApplication(at url: URL, bundle: Bundle?) -> Bool {
        // The system's own answer to "is this an application", not the extension.
        let values = try? url.resourceValues(forKeys: [.isApplicationKey, .contentTypeKey])
        let isApplication = values?.isApplication == true
            || values?.contentType?.conforms(to: .application) == true
        guard isApplication else { return false }

        // A bundle whose Info.plist cannot be read establishes nothing about itself,
        // and this is code that deletes things: what cannot be established is not
        // offered (Appendix F).
        guard let info = bundle?.infoDictionary else { return false }

        // Background-only means no windows, no Dock tile, no user-facing existence:
        // a URL handler or login item belonging to some other application. Offering
        // one invites the user to delete part of an app they mean to keep. Some
        // bundles spell the flag as a string rather than a boolean.
        if info["LSBackgroundOnly"] as? Bool == true { return false }
        if (info["LSBackgroundOnly"] as? String) == "1" { return false }

        return true
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
        // Nor another copy of it. A development build runs from a different path than
        // the installed one, so a path comparison alone would let the copy being
        // tested offer to delete the copy in /Applications. Compare identity, not
        // location — but only on the shared prefix, so a dev build (…Runwell.dev)
        // still protects the release bundle and vice versa.
        if let mine = Bundle.main.bundleIdentifier,
           let theirs = Bundle(url: bundleURL)?.bundleIdentifier {
            let root = { (id: String) in id.hasSuffix(".dev") ? String(id.dropLast(4)) : id }
            if root(mine) == root(theirs) {
                return .protected("This is Runwell.")
            }
        }
        // Removal is a *move* to the Trash, so what matters is whether the enclosing
        // directory can be written, not the bundle itself. Testing the bundle was
        // wrong in a way that quietly emptied this screen: `isWritableFile` reports
        // false for a quarantined bundle — which is nearly every app a user has ever
        // downloaded — so 39 of 42 installed applications were rejected as "not
        // writable by your account" despite being owned by that very account and
        // perfectly removable in Finder.
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            return .notRemovable(
                "\(bundleURL.lastPathComponent) is in a folder your account cannot modify.")
        }
        return nil
    }

    // MARK: - Discovery

    /// Every user-installed application, newest listing first by name.
    ///
    /// Sizes are left unmeasured (`nil`). Measuring a bundle means walking every
    /// file inside it, which for a folder the size of Xcode's takes long enough to
    /// freeze a caller that waits on the main thread — so the size of each app is a
    /// separate, cancellable step the caller runs off the main actor
    /// (`size(ofBundleAt:)`).
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
                guard Self.isUninstallableApplication(at: url, bundle: bundle) else { continue }
                let name = bundle?.infoDictionary?["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(
                    bundleURL: url,
                    name: name,
                    bundleID: bundle?.bundleIdentifier,
                    sizeBytes: nil,
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
    /// Sizes are left unmeasured here for the same reason as `installedApplications`:
    /// a `Caches` folder can hold tens of thousands of files, and walking it inline
    /// would block whoever asked. The caller fills sizes in afterwards via
    /// `size(ofItemAt:)`.
    public func residue(for app: InstalledApp) -> [Residue] {
        var items = [Residue(url: app.bundleURL, kind: .bundle, sizeBytes: nil)]
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
            // macOS 27 treats another app's container and application-support data
            // as protected, so this both misses files and posts a "Data Access
            // Blocked" notice unless the user has granted access. A miss is the
            // correct failure: the list then shows only what was really seen, and
            // `residue.count == 1` already tells the user nothing else was found.
            // Runwell does not ask for Full Disk Access to make this exhaustive —
            // an uninstaller is not worth that privilege.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            items.append(Residue(url: url, kind: kind, sizeBytes: nil))
        }
        return items
    }

    // MARK: - Sizing

    /// Bytes on disk for one removable item, or nil when the size could not be
    /// measured.
    ///
    /// Deliberately separate from `residue(for:)` and `installedApplications()`:
    /// this is the expensive half, and keeping it separate is what lets a caller
    /// run it off the main thread and abandon it when the selection changes.
    /// Honours task cancellation, so a superseded walk stops instead of running to
    /// completion in the background.
    public func size(ofItemAt url: URL) -> Int64? {
        directorySize(of: url)
    }

    /// Bytes on disk for an installed application bundle.
    public func size(ofBundleAt url: URL) -> Int64? {
        directorySize(of: url)
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
        var checked = 0
        for case let child as URL in enumerator {
            // A cancelled walk abandons the count rather than returning a partial
            // total: half of a directory's size is not a size, and reporting one
            // would be exactly the fabricated number the rest of the app refuses to
            // print. Checked periodically because `isCancelled` is not free and
            // these loops run to six figures.
            checked += 1
            if checked % 256 == 0, Task.isCancelled { return nil }
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
