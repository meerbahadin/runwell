import SwiftUI
import RunwellKit

/// Removing an installed application and the support files it leaves behind.
///
/// The list is deliberately quiet about what it cannot establish. A support file is
/// shown only when it was actually found on disk and matched by bundle identifier,
/// and a size it could not measure reads as an em dash rather than "0 bytes" — the
/// same rule the rest of the app applies to power measurements, applied here because
/// the cost of overclaiming is a deleted file the user did not mean to remove.
/// The left column: every application that can be uninstalled.
///
/// A column of a `NavigationSplitView`, like the application table, rather than a
/// pane inside an `HSplitView`. HSplitView sizes itself to its content, which left
/// the list floating small in the middle of an otherwise empty surface.
struct UninstallListView: View {
    @Bindable var model: UninstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Uninstall", subtitle: "Applications installed on this Mac")
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.md)
            applicationList
        }
        // Claim the column's width, but not its height: `maxHeight: .infinity` here
        // makes the stack claim the whole window including the area behind the title
        // bar, which lifts the heading up under it. The List below already expands
        // to fill whatever vertical space is left.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { model.reloadIfNeeded() }
    }

    private var applicationList: some View {
        List(model.applications, selection: $model.selectedID) { app in
            HStack(spacing: Theme.Spacing.row) {
                AppIconView(url: app.bundleURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).lineLimit(1)
                    Text(ByteText.string(app.sizeBytes))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if app.isRunning {
                    // Not an error, just a precondition the user can clear themselves.
                    Text("Running")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(app.id)
        }
        .overlay {
            if model.applications.isEmpty {
                ContentUnavailableView(
                    "No applications found",
                    systemImage: "questionmark.folder",
                    description: Text("Runwell looks in /Applications and your home Applications folder.")
                )
            }
        }
    }

}

/// The right column: what removing the selected application would delete.
struct UninstallDetailView: View {
    @Bindable var model: UninstallModel

    var body: some View {
        detail
            .alert(
                "Uninstall \(model.selected?.name ?? "")?",
                isPresented: $model.isConfirming,
                presenting: model.selected
            ) { _ in
                Button("Cancel", role: .cancel) {}
                Button("Move to Trash", role: .destructive) { model.confirmUninstall() }
            } message: { _ in
                Text(model.confirmationMessage)
            }
    }

    @ViewBuilder
    private var detail: some View {
        if let app = model.selected {
            VStack(alignment: .leading, spacing: Theme.Spacing.card) {
                header(app)
                Divider()

                Text("Select what to remove")
                    .font(Theme.Typography.headline)

                List {
                    ForEach(model.residue) { item in
                        Toggle(isOn: model.binding(for: item)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.kind.label)
                                    Text(displayPath(item.url))
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteText.string(item.sizeBytes))
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        // The bundle is the point of the operation; unchecking it
                        // would leave the app installed and remove only its data,
                        // which is not what "uninstall" means.
                        .disabled(item.kind == .bundle)
                    }
                }
                .listStyle(.inset)
                // A List has no intrinsic height: inside a VStack it claims all the
                // vertical space it can get, which squeezed the surrounding columns
                // until the window read as empty. Worst with a single row, which is
                // why an app with no support files was the one that broke. Bound it
                // to its content instead, up to a scrolling ceiling.
                .frame(height: min(CGFloat(model.residue.count) * 44 + 16, 320))
                .fixedSize(horizontal: false, vertical: true)

                if model.residue.count == 1 {
                    Text("No support files were found for this app. Runwell matches them "
                         + "by bundle identifier, so it will not list files it cannot "
                         + "confirm belong to this app. macOS also protects some app "
                         + "data from being read, so there may be more than this shows.")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                footer(app)
            }
            .padding(Theme.Spacing.section)
            // Fill the column rather than hugging the content: without this the
            // pane centres itself and the file list reads as a floating card.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "Select an application",
                systemImage: "trash",
                description: Text("Choose an app to see what removing it would delete.")
            )
        }
    }

    private func header(_ app: UninstallService.InstalledApp) -> some View {
        HStack(spacing: Theme.Spacing.card) {
            AppIconView(url: app.bundleURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(Theme.Typography.title)
                if let id = app.bundleID {
                    Text(id)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ app: UninstallService.InstalledApp) -> some View {
        if let outcome = model.lastOutcome {
            // Report per item rather than a blanket success: a partial failure that
            // read as "Uninstalled" would leave the user believing files are gone
            // that are still on disk.
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                if outcome.isCompleteSuccess {
                    Label("Moved \(outcome.trashed.count) item(s) to the Trash.",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Moved \(outcome.trashed.count) item(s); \(outcome.failed.count) could not be removed.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    ForEach(outcome.failed, id: \.url) { failure in
                        Text("\(failure.url.lastPathComponent): \(failure.reason)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(Theme.Typography.callout)
        }

        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Text(model.selectionSummary)
                .font(Theme.Typography.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Move to Trash", role: .destructive) { model.isConfirming = true }
                .disabled(app.isRunning)
                .help(app.isRunning
                      ? "Quit \(app.name) before uninstalling it."
                      : "Move the selected items to the Trash.")
        }
    }

    /// `~`-relative, because the absolute path of a home directory is noise.
    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }
}

/// Formats byte counts, and says so plainly when a size is unknown.
enum ByteText {
    static func string(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A file's Finder icon. Fetching an icon is a filesystem hit, so it is resolved
/// once per URL and cached — the same lesson as the application list, where doing
/// this per frame cost 38 ms.
struct AppIconView: View {
    let url: URL
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: url))
            .resizable()
            .frame(width: size, height: size)
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [URL: NSImage] = [:]

    func icon(for url: URL) -> NSImage {
        if let cached = cache[url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[url] = icon
        return icon
    }
}

@MainActor
@Observable
final class UninstallModel {
    private let service = UninstallService()

    var applications: [UninstallService.InstalledApp] = []
    /// Setting this is what drives the file list: the List binds straight to it, so
    /// recomputing here rather than in a separate call is the only way the two
    /// cannot drift apart.
    var selectedID: URL? {
        didSet {
            guard selectedID != oldValue else { return }
            lastOutcome = nil
            errorMessage = nil
            refreshResidue()
        }
    }
    var residue: [UninstallService.Residue] = []
    var excluded: Set<URL> = []
    var isConfirming = false
    var lastOutcome: UninstallService.Outcome?
    var errorMessage: String?

    /// True while sizes for the current selection are still being measured, so the
    /// footer can say so instead of printing a total that is about to change.
    private(set) var isMeasuringResidue = false

    /// The in-flight sizing walks. Held so that changing the selection, or
    /// reloading, cancels work whose answer nobody is waiting for any more —
    /// without this, clicking through ten apps leaves ten filesystem walks running.
    private var residueSizingTask: Task<Void, Never>?
    private var applicationSizingTask: Task<Void, Never>?

    var selected: UninstallService.InstalledApp? {
        applications.first { $0.id == selectedID }
    }

    func reload() {
        applications = service.installedApplications()
        startMeasuringApplications()
        refreshResidue()
    }

    /// Sizes each listed bundle off the main actor, assigning results back as they
    /// arrive so the list stays responsive while /Applications is measured.
    private func startMeasuringApplications() {
        applicationSizingTask?.cancel()
        let service = self.service
        let urls = applications.map(\.bundleURL)
        applicationSizingTask = Task { [weak self] in
            for url in urls {
                if Task.isCancelled { return }
                let size = await Task.detached(priority: .utility) {
                    service.size(ofBundleAt: url)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.applySize(size, toApplicationAt: url)
            }
        }
    }

    /// Row identity is the bundle URL rather than an index: the list may have been
    /// reloaded while this walk was in flight, and writing by position would put a
    /// size on the wrong app.
    private func applySize(_ size: Int64?, toApplicationAt url: URL) {
        guard let index = applications.firstIndex(where: { $0.bundleURL == url }) else { return }
        let app = applications[index]
        applications[index] = UninstallService.InstalledApp(
            bundleURL: app.bundleURL,
            name: app.name,
            bundleID: app.bundleID,
            sizeBytes: size,
            isRunning: app.isRunning
        )
    }

    /// Scanning /Applications sizes every bundle on disk, which is far too costly to
    /// repeat each time the column re-renders. The list is loaded once and refreshed
    /// explicitly after an uninstall.
    func reloadIfNeeded() {
        guard applications.isEmpty else { return }
        reload()
    }

    /// Recomputed whenever the selection changes, so the file list always describes
    /// the app actually shown.
    func refreshResidue() {
        residueSizingTask?.cancel()
        guard let app = selected else {
            residue = []
            isMeasuringResidue = false
            return
        }
        // The paths are cheap to find; only their sizes are expensive. Showing them
        // straight away is what keeps the click responsive — this used to walk every
        // support folder inline, which froze the window on any app with a large
        // cache until the walk finished.
        residue = service.residue(for: app)
        excluded = []
        startMeasuringResidue(for: app.bundleURL)
    }

    private func startMeasuringResidue(for bundleURL: URL) {
        let service = self.service
        let urls = residue.map(\.url)
        guard !urls.isEmpty else {
            isMeasuringResidue = false
            return
        }
        isMeasuringResidue = true
        residueSizingTask = Task { [weak self] in
            for url in urls {
                if Task.isCancelled { return }
                let size = await Task.detached(priority: .utility) {
                    service.size(ofItemAt: url)
                }.value
                guard let self, !Task.isCancelled else { return }
                // The selection may have moved on while this walk ran; a size for
                // the previous app must not land in the current app's list.
                guard self.selectedID == bundleURL else { return }
                self.applySize(size, toResidueAt: url)
            }
            guard let self, !Task.isCancelled, self.selectedID == bundleURL else { return }
            self.isMeasuringResidue = false
        }
    }

    private func applySize(_ size: Int64?, toResidueAt url: URL) {
        guard let index = residue.firstIndex(where: { $0.url == url }) else { return }
        let item = residue[index]
        residue[index] = UninstallService.Residue(
            url: item.url, kind: item.kind, sizeBytes: size
        )
    }

    var selectedResidue: [UninstallService.Residue] {
        residue.filter { !excluded.contains($0.url) }
    }

    func binding(for item: UninstallService.Residue) -> Binding<Bool> {
        Binding(
            get: { !self.excluded.contains(item.url) },
            set: { isOn in
                if isOn { self.excluded.remove(item.url) }
                else { self.excluded.insert(item.url) }
            }
        )
    }

    /// Only sums the sizes it actually knows, and says how many it does not, rather
    /// than presenting a total that silently omits them.
    var selectionSummary: String {
        let chosen = selectedResidue
        // While sizes are still being walked, a total would be a number that is
        // about to change — worse here than saying nothing yet, because the user
        // reads it to decide what they are about to delete.
        if isMeasuringResidue {
            return "\(chosen.count) item(s), measuring…"
        }
        let known = chosen.compactMap(\.sizeBytes)
        let total = known.reduce(0, +)
        let unknown = chosen.count - known.count
        var text = "\(chosen.count) item(s), \(ByteText.string(total))"
        if unknown > 0 { text += " (\(unknown) of unknown size)" }
        return text
    }

    var confirmationMessage: String {
        let chosen = selectedResidue
        return "\(chosen.count) item(s) will be moved to the Trash. "
            + "You can put them back from the Trash if this was a mistake."
    }

    func confirmUninstall() {
        guard let app = selected else { return }
        errorMessage = nil
        switch service.uninstall(app: app, items: selectedResidue, userConfirmed: true) {
        case .success(let outcome):
            lastOutcome = outcome
            // Re-list from disk rather than assuming the row is gone: if the bundle
            // failed to move, it must stay in the list.
            reload()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}
