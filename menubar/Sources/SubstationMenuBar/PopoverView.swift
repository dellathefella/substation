import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.offline { offlineBanner }
            if model.routerDisabled { routerOffBanner }
            if model.degradedAuto { degradedBanner }

            statsRow

            Divider()

            modelsSection

            if model.clusterEnabled && !model.nodes.isEmpty {
                Divider()
                nodesSection
            }

            Divider()

            routingSection

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusItemController.logoImage(template: false) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 15, height: 17)
            Text("Substation")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            statePill
        }
    }

    private var stateColor: Color {
        if model.offline { return .secondary }
        if model.isPaused { return .yellow }
        return .green
    }

    private var statePill: some View {
        Text(model.stateLabel.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(stateColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(stateColor.opacity(0.15))
            )
    }

    // MARK: Offline banner

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Daemon offline")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.baseURL)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Retry") {
                Task { await model.refresh() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var routerOffBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.slash")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-router disabled")
                    .font(.system(size: 12, weight: .semibold))
                Text("Single-model mode — auto uses \(model.status?.defaultModel ?? "the only catalog model")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }

    private var degradedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Orchestrator unavailable")
                    .font(.system(size: 12, weight: .semibold))
                Text("Auto routing on default model \(model.status?.defaultModel ?? "?")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    // MARK: Stats

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                stat("Uptime", model.uptimeLabel)
                statDivider
                stat("Req/min", shortNumber(model.requestsPerMin))
                statDivider
                stat("Tok/s", shortNumber(model.tokensPerSec))
                statDivider
                stat("Active", model.requestsActive.map(String.init) ?? "—")
                statDivider
                stat("Cache", model.cacheHitLabel)
            }
            HStack(alignment: .top, spacing: 0) {
                stat("CPU", model.status?.system?.cpuPct.map { String(format: "%.0f%%", $0) } ?? "—")
                statDivider
                stat("GPU", model.status?.system?.gpuPct.map { String(format: "%.0f%%", $0) } ?? "—")
                statDivider
                stat("Net↓", mbps(model.status?.system?.rxBps))
                statDivider
                stat("Net↑", mbps(model.status?.system?.txBps))
                statDivider
                stat("RAM", ramLabel)
            }
            if let usage = model.metrics?.tokenUsage {
                Text("\(shortNumber(Double(usage.promptTotal ?? 0))) in · \(shortNumber(Double(usage.completionTotal ?? 0))) out tokens")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var ramLabel: String {
        guard let m = model.status?.memory, let used = m.usedGB, let total = m.totalGB else { return "—" }
        return String(format: "%.0f/%.0fG", used, total)
    }

    private func mbps(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v / 1_048_576)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 24)
    }

    private func shortNumber(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f", v)
    }

    // MARK: Models

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Engines")
                Spacer()
                if !model.engines.isEmpty {
                    Button {
                        model.restartAllEngines()
                    } label: {
                        HStack(spacing: 3) {
                            if model.restartingAll {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("All")
                        }
                        .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.restartingAll || model.offline)
                    .help("Restart every loaded engine")
                }
            }
            if model.engines.isEmpty {
                Text(model.loadedModels.isEmpty ? "No engines loaded" : "\(model.loadedModels.count) models loaded")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.engines) { e in
                    HStack(spacing: 6) {
                        Text(e.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let tps = model.tokS(for: e.displayName), tps > 0 {
                            Text(String(format: "%.0f tok/s", tps))
                                .font(.system(size: 9)).foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        if e.isSplit {
                            Text("RPC")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.purple)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.purple.opacity(0.15)))
                        }
                        Text(e.displayNode)
                            .font(.system(size: 9)).foregroundColor(.secondary)
                            .lineLimit(1)
                        Button {
                            model.restartEngine(e.displayName)
                        } label: {
                            if model.restarting.contains(e.displayName) {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.restarting.contains(e.displayName) || model.offline)
                        .help("Restart \(e.displayName)@\(e.displayNode)")
                    }
                }
            }
        }
    }

    // MARK: Nodes

    private var nodesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Cluster Nodes")
            ForEach(model.nodes) { node in
                HStack(spacing: 8) {
                    Circle()
                        .fill(node.isOnline ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(node.displayId)
                        .font(.system(size: 11, weight: .medium))
                    if let frac = node.ramFraction {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.2))
                                Capsule().fill(Color.accentColor)
                                    .frame(width: max(2, geo.size.width * frac))
                            }
                        }
                        .frame(height: 6)
                        .frame(maxWidth: .infinity)
                    }
                    if let used = node.ramUsedGB, let total = node.ramTotalGB {
                        Text(String(format: "%.0f/%.0f GB", used, total))
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Routing decisions

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Recent Routing Decisions")
            if model.events.isEmpty {
                Text("No recent events")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.events) { event in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tierColor(event.tier ?? ""))
                            .frame(width: 4, height: 14)
                        Text(event.type ?? "event")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(event.detail)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        Button {
            openDashboard()
        } label: {
            HStack {
                Image(systemName: "safari")
                Text("Open Dashboard")
                Spacer()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func openDashboard() {
        guard let url = URL(string: model.baseURL + "/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
    }

    private func tierColor(_ tier: String) -> Color {
        switch tier.lowercased() {
        case "fast": return .blue
        case "balanced": return .orange
        case "smart": return .purple
        default: return .secondary
        }
    }
}
