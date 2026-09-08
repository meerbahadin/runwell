import SwiftUI
import PowerTaskKit

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
            Text(compact ? String(provenance.badge.prefix(1)) : provenance.badge)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption2)
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
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
struct AppIcon: View {
    let bundleURL: URL?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let bundleURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: bundleURL.path))
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
                .font(.caption)
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
