import SwiftUI
import RunwellKit

/// Removing an installed application and the support files it leaves behind.
///
/// The list is deliberately quiet about what it cannot establish. A support file is
/// shown only when it was actually found on disk and matched by bundle identifier,
/// and a size it could not measure reads as an em dash rather than "0 bytes" — the
/// same rule the rest of the app applies to power measurements, applied here because
/// the cost of overclaiming is a deleted file the user did not mean to remove.
struct UninstallView: View {
    @State private var model = UninstallModel()

    var body: some View {
        HSplitView {
            applicationList
                .frame(minWidth: 240, idealWidth: 280)
            detail
                .frame(minWidth: 320)
        }
        .navigationTitle("Uninstall")
        .task { model.reload() }
        .alert(
            "Uninstall \(model.selected?.name ?? "")?",
            isPresented: $model.isConfirming,
            presenting: model.selected
        ) { app in
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.confirmUninstall() }
        } message: { _ in
            Text(model.confirmationMessage)
        }
    }

    private var applicationList: some View {
        List(model.applications, selection: $model.selectedID) { app in
            HStack(spacing: Theme.Spacing.row) {
                AppIconView(url: app.bundleURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).lineLimit(1)
                    Text(ByteText.string(app.sizeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if app.isRunning {
                    // Not an error, just a precondition the user can clear themselves.
                    Text("Running")
                        .font(.caption2)
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

    @ViewBuilder
    private var detail: some View {
        if let app = model.selected {
            VStack(alignment: .leading, spacing: Theme.Spacing.card) {
                header(app)
                Divider()

                Text("Select what to remove")
                    .font(.headline)

                List {
                    ForEach(model.residue) { item in
                        Toggle(isOn: model.binding(for: item)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.kind.label)
                                    Text(displayPath(item.url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteText.string(item.sizeBytes))
                                    .font(.caption)
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

                if model.residue.count == 1 {
                    Text("No support files were found for this app. Runwell matches them "
                         + "by bundle identifier, so it will not list files it cannot "
                         + "confirm belong to this app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                footer(app)
            }
            .padding(Theme.Spacing.section)
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
                Text(app.name).font(.title2)
                if let id = app.bundleID {
                    Text(id)
                        .font(.caption)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }

        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Text(model.selectionSummary)
                .font(.callout)
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

    var selected: UninstallService.InstalledApp? {
        applications.first { $0.id == selectedID }
    }

    func reload() {
        applications = service.installedApplications()
        refreshResidue()
    }

    /// Recomputed whenever the selection changes, so the file list always describes
    /// the app actually shown.
    func refreshResidue() {
        guard let app = selected else {
            residue = []
            return
        }
        residue = service.residue(for: app)
        excluded = []
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
