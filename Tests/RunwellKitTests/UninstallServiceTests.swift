import Testing
import Foundation
@testable import RunwellKit

/// The uninstaller deletes things, so these tests are mostly about what it refuses
/// to do. A false negative here is a missed leftover; a false positive is someone
/// else's data in the Trash.
@Suite("Uninstall policy")
struct UninstallServiceTests {
    private let service = UninstallService()

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runwell-uninstall-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - What must never be offered

    @Test("System applications are refused", arguments: [
        "/System/Applications/Safari.app",
        "/System/Library/CoreServices/Finder.app",
        "/usr/local/bin/tool",
        "/Library/Apple/System/Something.app",
    ])
    func systemPathsAreProtected(path: String) {
        let error = service.evaluate(bundleURL: URL(fileURLWithPath: path))
        #expect(error != nil, "\(path) must not be removable")
        if case .protected = error {} else {
            Issue.record("\(path) should be .protected, got \(String(describing: error))")
        }
    }

    /// Deleting the running executable out from under itself.
    @Test("Runwell refuses to uninstall itself")
    func refusesSelf() {
        let error = service.evaluate(bundleURL: Bundle.main.bundleURL)
        #expect(error != nil)
    }

    /// The protection is on the resolved path, so a route through `..` that lands
    /// inside /System must be refused *as protected*.
    ///
    /// The distinction matters: `URL.path` does not resolve `..`, so without
    /// standardizing, this path fails the prefix check and falls through to the
    /// writability test — which also refuses it, but as `.notRemovable`, and only
    /// because /System happens to be read-only. On a writable protected location
    /// that fallback would not catch it at all, so the test asserts the specific
    /// case rather than merely that something was returned.
    @Test("A path that resolves into a protected location is refused as protected")
    func traversalIsResolvedBeforeChecking() {
        let sneaky = URL(fileURLWithPath: "/Applications/../System/Applications/Safari.app")
        guard case .protected = service.evaluate(bundleURL: sneaky) else {
            Issue.record("traversal into /System must be refused as .protected")
            return
        }
    }

    // MARK: - Residue matching

    /// The rule that keeps this safe: an app with no bundle identifier gets no
    /// support-file matching at all, rather than falling back to its name.
    @Test("An app without a bundle identifier offers only its own bundle")
    func noBundleIDMeansNoResidue() {
        let app = UninstallService.InstalledApp(
            bundleURL: temporaryDirectory().appendingPathComponent("Thing.app"),
            name: "Thing", bundleID: nil, sizeBytes: 100, isRunning: false
        )
        let residue = service.residue(for: app)
        #expect(residue.count == 1)
        #expect(residue.first?.kind == .bundle)
    }

    @Test("An empty bundle identifier is treated as absent, not matched as a prefix")
    func emptyBundleIDMatchesNothing() {
        let app = UninstallService.InstalledApp(
            bundleURL: temporaryDirectory().appendingPathComponent("Thing.app"),
            name: "Thing", bundleID: "", sizeBytes: 100, isRunning: false
        )
        #expect(service.residue(for: app).count == 1)
    }

    /// Support files that do not exist are not listed — the UI shows what is on
    /// disk, never a speculative path.
    @Test("Only support files that exist are listed")
    func onlyExistingResidueIsListed() {
        let app = UninstallService.InstalledApp(
            bundleURL: temporaryDirectory().appendingPathComponent("Ghost.app"),
            name: "Ghost", bundleID: "com.example.definitely-not-installed-\(UUID().uuidString)",
            sizeBytes: nil, isRunning: false
        )
        let residue = service.residue(for: app)
        #expect(residue.count == 1, "a bundle ID nothing owns must match no support files")
    }

    // MARK: - Refusing to act

    @Test("Uninstalling without confirmation is refused")
    func requiresConfirmation() async {
        let app = UninstallService.InstalledApp(
            bundleURL: temporaryDirectory().appendingPathComponent("Thing.app"),
            name: "Thing", bundleID: "com.example.thing", sizeBytes: 1, isRunning: false
        )
        let result = await MainActor.run {
            service.uninstall(app: app, items: [], userConfirmed: false)
        }
        guard case .failure = result else {
            Issue.record("unconfirmed uninstall must fail")
            return
        }
    }

    // MARK: - Sizing

    /// Appendix F applied to file sizes: an unmeasurable size is nil, never 0,
    /// because "0 bytes" reads as "removing this frees nothing".
    @Test("A size that cannot be measured is nil rather than zero")
    func unknownSizeIsNil() {
        let missing = URL(fileURLWithPath: "/definitely/not/here-\(UUID().uuidString)")
        #expect(service.directorySize(of: missing) == nil)
    }

    @Test("A directory's size is the sum of the files inside it")
    func directorySizeSumsChildren() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data(repeating: 0, count: 8_192)
        try payload.write(to: directory.appendingPathComponent("a.bin"))
        try payload.write(to: directory.appendingPathComponent("b.bin"))

        let size = try #require(service.directorySize(of: directory))
        // Allocated size rounds up to block size, so assert a floor rather than an
        // exact figure.
        #expect(size >= Int64(payload.count * 2))
    }

    /// An app whose enclosing folder the user can write is removable, whatever the
    /// bundle's own permission bits say. `isWritableFile` on the bundle reports false
    /// for any quarantined download, which rejected 39 of 42 installed applications
    /// and left this screen all but empty.
    @Test("A quarantined app the user owns is still removable")
    func quarantinedAppIsRemovable() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("Quarantined.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        // The attribute macOS sets on everything downloaded from the internet.
        _ = try? bundle.withUnsafeFileSystemRepresentation { path -> Int32 in
            let value = "0181;00000000;Safari;"
            return setxattr(path, "com.apple.quarantine", value, value.utf8.count, 0, 0)
        }
        #expect(service.evaluate(bundleURL: bundle) == nil,
                "an app inside a writable folder must be removable")
    }

    // MARK: - What counts as an application

    /// A URL handler ships as a `.app` but has no interface and belongs to whatever
    /// installed it. Offering one for uninstall invites the user to delete part of
    /// another application without realising it.
    ///
    /// A menu-bar app (`LSUIElement`) is the opposite case and must stay listed: no
    /// Dock tile, but an application the user installed and may want to remove.
    @Test("Background-only helpers are excluded, menu-bar apps are not")
    func onlyBackgroundOnlyHelpersAreExcluded() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        func makeBundle(_ name: String, info: [String: Any]) throws -> (URL, Bundle?) {
            let app = directory.appendingPathComponent("\(name).app", isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            var plist = info
            plist["CFBundleName"] = name
            plist["CFBundleIdentifier"] = "com.example.\(name)"
            plist["CFBundleExecutable"] = name
            plist["CFBundlePackageType"] = "APPL"
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            FileManager.default.createFile(atPath: macos.appendingPathComponent(name).path,
                                           contents: Data())
            return (app, Bundle(url: app))
        }

        let (normalURL, normal) = try makeBundle("Normal", info: [:])
        let (bgURL, bg) = try makeBundle("Handler", info: ["LSBackgroundOnly": true])
        let (stringURL, stringly) = try makeBundle("Stringly", info: ["LSBackgroundOnly": "1"])
        let (menuURL, menu) = try makeBundle("MenuBar", info: ["LSUIElement": true])

        #expect(UninstallService.isUninstallableApplication(at: normalURL, bundle: normal))
        #expect(!UninstallService.isUninstallableApplication(at: bgURL, bundle: bg))
        #expect(!UninstallService.isUninstallableApplication(at: stringURL, bundle: stringly))
        // Docker, Maccy and Scroll Reverser all set this; they belong in the list.
        #expect(UninstallService.isUninstallableApplication(at: menuURL, bundle: menu),
                "a menu-bar app is still an application the user installed")
        // A bundle whose Info.plist cannot be read establishes nothing, so it is not offered.
        #expect(!UninstallService.isUninstallableApplication(at: normalURL, bundle: nil))
    }

    // MARK: - Listing is cheap, sizing is separate

    /// Sizing inside `residue(for:)` froze the window on any app with a large cache:
    /// the walk ran on the main thread inside the selection setter, and the UI went
    /// blank until it finished. Discovery must stay cheap, with sizes filled in
    /// afterwards, off the main actor.
    @Test("Listing support files does not measure them")
    func residueDefersSizing() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let app = UninstallService.InstalledApp(
            bundleURL: bundle, name: "Example", bundleID: "com.example.app",
            sizeBytes: nil, isRunning: false
        )
        let items = service.residue(for: app)

        #expect(!items.isEmpty)
        #expect(
            items.allSatisfy { $0.sizeBytes == nil },
            "residue(for:) must not walk the filesystem; sizes arrive via size(ofItemAt:)"
        )
    }

    /// The same contract for the application list: opening the tab must not block on
    /// measuring every bundle in /Applications.
    @Test("Listing installed applications does not measure them")
    func installedApplicationsDeferSizing() {
        let apps = service.installedApplications()
        #expect(
            apps.allSatisfy { $0.sizeBytes == nil },
            "installedApplications() must not walk bundles; sizes arrive via size(ofBundleAt:)"
        )
    }

    /// The deferred sizing call still has to produce a real answer, or the split
    /// would trade a freeze for a column of em dashes.
    @Test("The deferred sizing call measures what the listing skipped")
    func deferredSizingMeasures() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data(repeating: 0, count: 4_096)
        try payload.write(to: directory.appendingPathComponent("payload.bin"))

        let size = try #require(service.size(ofItemAt: directory))
        #expect(size >= Int64(payload.count))
    }

    /// A cancelled walk must report "unknown", never the partial total it had
    /// accumulated — a half-counted directory is exactly the fabricated number the
    /// rest of the app refuses to print.
    @Test("A cancelled measurement returns nil rather than a partial total")
    func cancelledSizingReturnsNil() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Enough files that the walk is still running when cancellation lands, and
        // more than the 256-file cancellation check interval.
        let payload = Data(repeating: 0, count: 512)
        for index in 0..<2_000 {
            try payload.write(to: directory.appendingPathComponent("file-\(index).bin"))
        }

        let service = self.service
        let task = Task.detached(priority: .utility) { service.size(ofItemAt: directory) }
        task.cancel()
        #expect(await task.value == nil)
    }
}
