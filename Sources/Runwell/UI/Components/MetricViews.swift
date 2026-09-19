import SwiftUI
import RunwellKit

/// Section 5.3's normalized display: raw macOS-style CPU percentage divided across
/// every core, so a fully busy 12-core Mac reads 100% instead of 1200%.
///
/// This used to be applied inside `MetricEngine`, mutating the canonical value every
/// other consumer read — `InsightEngine`'s fixed background-CPU threshold, grouping,
/// sort order and `HistoryStore` all silently changed meaning depending on this
/// display preference. It is now a pure `.map` applied only where a CPU number is
/// about to be shown to the user, on a copy that carries the original provenance
/// forward unchanged.
func displayCPU(_ raw: IntervalMetric<Double>, normalize: Bool, coreCount: Int) -> IntervalMetric<Double> {
    guard normalize, coreCount > 0 else { return raw }
    return raw.map { $0 / Double(coreCount) }
}

/// Section 3 / 8.5. Renders a metric together with its provenance.
///
/// Section 8.5 forbids encoding severity by color alone, so every state carries text
/// or a symbol as well, and unavailable values are an em dash with an explanation
/// rather than a fabricated zero.
struct MetricText: View {
    let metric: IntervalMetric<Double>
    var format: String = "%.1f"
    var suffix: String = ""
    var monospaced: Bool = true

    var body: some View {
        Text(metric.formatted(format, suffix: suffix))
            .monospacedDigit()
            .foregroundStyle(metric.isAvailable ? .primary : .secondary)
            .help(helpText)
            .accessibilityLabel(accessibilityLabel)
    }

    private var helpText: String {
        if let reason = metric.reasonUnavailable {
            return reason.userFacing
        }
        return "\(metric.provenance.badge): \(metric.provenance.explanation)"
    }

    private var accessibilityLabel: String {
        guard metric.isAvailable else {
            return "Unavailable. \(metric.reasonUnavailable?.userFacing ?? "")"
        }
        return "\(metric.formatted(format, suffix: suffix)), \(metric.provenance.badge)"
    }
}

/// A small badge naming where a value came from (Section 3).
struct ProvenanceBadge: View {
    let provenance: MetricProvenance
    var compact = false

    var body: some View {
        Label {
            // A single letter said nothing — "f(x) D" reads as noise beside a
            // number, and "E" cannot distinguish Estimated from Experimental. The
            // compact form drops the icon instead of the word: Section 8.5 forbids
            // colour *alone*, and the word satisfies that on its own, where a
            // lone initial does not.
            Text(provenance.badge)
        } icon: {
            if !compact { Image(systemName: symbol) }
        }
        .font(Theme.Typography.caption)
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
        // Without an explicit shape the hover region is only the glyphs, so the
        // capsule's padding is dead space and the tooltip mostly refuses to open.
        .contentShape(Capsule())
        .onHover { _ in }
        .help(provenance.explanation)
        .accessibilityLabel("\(provenance.badge). \(provenance.explanation)")
    }

    // Symbols carry the meaning; color only reinforces it (Section 8.5).
    private var symbol: String {
        switch provenance {
        case .measured: "checkmark.seal"
        case .derived: "function"
        case .estimated: "chart.line.uptrend.xyaxis"
        case .experimental: "flask"
        case .unavailable: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch provenance {
        case .measured: .green
        case .derived: .blue
        case .estimated: .orange
        case .experimental: .purple
        case .unavailable: .secondary
        }
    }
}

/// A memory value formatted in the user's preferred byte units.
struct MemoryText: View {
    let metric: IntervalMetric<UInt64>

    var body: some View {
        Text(formatted)
            .monospacedDigit()
            .foregroundStyle(metric.isAvailable ? .primary : .secondary)
            .help(metric.isAvailable
                  ? "\(metric.provenance.badge): \(metric.provenance.explanation)"
                  : (metric.reasonUnavailable?.userFacing ?? "Unavailable"))
            .accessibilityLabel(metric.isAvailable ? "\(formatted), \(metric.provenance.badge)" : "Unavailable")
    }

    private var formatted: String {
        guard let bytes = metric.value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

/// The application icon, loaded from the resolved bundle.
/// An app icon resolved from a bundle identifier rather than a path, for history
/// rows: Section 7.1 keeps filesystem paths out of the database, so the stored
/// identifier is all there is to go on. Falls back to a generic glyph when the app
/// is no longer installed — history outlives installs.
struct AppIconByBundleID: View {
    let bundleID: String?
    var size: CGFloat = 16

    var body: some View {
        if let url = bundleID.flatMap({ AppIconCache.bundleURL(forBundleID: $0) }) {
            AppIcon(bundleURL: url, size: size)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Application icons, kept in memory once looked up.
///
/// `NSWorkspace.icon(forFile:)` touches the filesystem — about 0.23 ms per call on
/// a warm system. The application list calls it once per row inside `body`, so a
/// list of ~166 applications spent roughly 38 ms per redraw fetching icons that
/// never change: more than twice a 60 Hz frame budget, and the reason the list
/// stuttered while scrolling or sorting.
///
/// Main-actor isolated rather than locked: every caller is a SwiftUI `body`, which
/// already runs there. Icons live for the process lifetime, which is correct for
/// this key space — one entry per installed application the user is running, a few
/// hundred at most, each a small NSImage.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }

    /// Resolved bundle URLs, cached for the same reason: resolution is a Launch
    /// Services lookup, and the history view calls it per row.
    private static var bundleURLs: [String: URL?] = [:]

    static func bundleURL(forBundleID bundleID: String) -> URL? {
        if let cached = bundleURLs[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        bundleURLs[bundleID] = url
        return url
    }
}

struct AppIcon: View {
    let bundleURL: URL?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let bundleURL {
                Image(nsImage: AppIconCache.icon(forPath: bundleURL.path))
                    .resizable()
            } else {
                // A command-line tool or unbundled executable.
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Section 8.2 / 8.5: a short state label with a symbol, never color alone.
struct StatusBadge: View {
    let status: ApplicationStatus

    var body: some View {
        if let label = status.label, let symbol = status.symbolName {
            Label(label, systemImage: symbol)
                .font(Theme.Typography.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.15), in: Capsule())
                .foregroundStyle(tint)
                .accessibilityLabel(label)
        }
    }

    private var tint: Color {
        switch status {
        case .normal: .secondary
        case .highEnergy: .orange
        case .backgroundActivity: .purple
        case .highMemory: .blue
        }
    }
}
