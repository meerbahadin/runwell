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
}
