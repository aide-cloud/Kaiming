import AppKit
import SwiftUI

/// 菜单栏面板的「系统功能」分区：传感器、网络、磁盘与系统身份。
struct SystemFeaturesPane: View {
    @ObservedObject var monitor: SystemMonitor
    @EnvironmentObject private var settings: SettingsStore

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricsGrid
            networkCard
            diskCard
            statusBarPicker
            identityFooter
        }
    }

    // MARK: 指标

    private var metricsGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            SystemStatTile(
                icon: "thermometer.medium",
                title: "CPU 温度",
                value: SystemFormat.temperature(monitor.sensors.cpuTemperature),
                caption: temperatureCaption,
                tint: SystemPalette.amber
            )
            SystemStatTile(
                icon: "gauge.with.dots.needle.50percent",
                title: "CPU 负载",
                value: SystemFormat.percent(monitor.cpu.usage),
                caption: cpuCaption,
                tint: SystemPalette.mint
            )
            SystemStatTile(
                icon: "fanblades",
                title: "风扇转速",
                value: SystemFormat.rpm(monitor.sensors.fanRPM),
                caption: fanCaption,
                tint: SystemPalette.sky
            )
            SystemStatTile(
                icon: "memorychip",
                title: "内存占用",
                value: "\(monitor.memory.usedPercent)%",
                caption: memoryCaption,
                tint: SystemPalette.violet
            )
        }
    }

    private var temperatureCaption: String {
        if let source = monitor.sensors.temperatureSource {
            return "来源：\(source)"
        }
        return "此机型未暴露温度传感器"
    }

    private var cpuCaption: String {
        guard monitor.cpu.coreCount > 0 else { return "正在采样…" }
        return "\(monitor.cpu.coreCount) 核 · 1 分钟负载 \(String(format: "%.2f", monitor.cpu.loadAverage))"
    }

    private var fanCaption: String {
        guard let rpm = monitor.sensors.fanRPM, rpm > 0 else { return "无风扇或传感器不可用" }
        let minRPM = SystemFormat.signedRPM(monitor.sensors.fanMinRPM)
        let maxRPM = SystemFormat.signedRPM(monitor.sensors.fanMaxRPM)
        if minRPM == "—", maxRPM == "—" { return "当前转速" }
        return "范围 \(minRPM) – \(maxRPM)"
    }

    private var memoryCaption: String {
        guard monitor.memory.totalBytes > 0 else { return "读取中…" }
        return "已用 \(SystemFormat.bytes(monitor.memory.usedBytes)) / \(SystemFormat.bytes(monitor.memory.totalBytes))"
    }

    private var diskCaption: String {
        guard monitor.disk.totalBytes > 0 else { return "读取中…" }
        return "可用 \(SystemFormat.bytes(monitor.disk.availableBytes)) / 共 \(SystemFormat.bytes(monitor.disk.totalBytes))"
    }

    // MARK: 网络

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("网络")
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                Text(monitor.network.interfaceName ?? "未连接")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 14) {
                rateBadge(
                    icon: "arrow.down",
                    title: "下载",
                    value: SystemFormat.rate(monitor.network.downloadBytesPerSecond),
                    color: SystemPalette.mint
                )
                rateBadge(
                    icon: "arrow.up",
                    title: "上传",
                    value: SystemFormat.rate(monitor.network.uploadBytesPerSecond),
                    color: SystemPalette.sky
                )
                Spacer(minLength: 0)
            }

            NetworkSparkline(points: monitor.networkHistory)
        }
        .panelCard()
    }

    // MARK: 磁盘

    private var diskCard: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("磁盘")
                    .font(.system(size: 10, weight: .semibold))
                Text(monitor.disk.volumeName ?? "启动磁盘")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(monitor.disk.totalBytes > 0 ? "\(monitor.disk.usedPercent)%" : "—")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            SystemMeter(fraction: monitor.disk.usedFraction, color: SystemPalette.violet, height: 6)
            HStack(spacing: 6) {
                Text(diskCaption)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("存储管理") {
                    openStorageSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 9))
            }
        }
        .panelCard()
    }

    private func openStorageSettings() {
        let workspace = NSWorkspace.shared
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage"),
           workspace.open(url) {
            return
        }
        workspace.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func rateBadge(icon: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
    }

    // MARK: 状态栏指标

    private var statusBarPicker: some View {
        HStack(spacing: 4) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text("状态栏")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(SystemStatusMetric.allCases) { metric in
                statusBarChip(metric)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .help("选择在菜单栏展示的指标；面板打开时 2 秒、收起后 3 秒刷新")
    }

    private func statusBarChip(_ metric: SystemStatusMetric) -> some View {
        let selected = settings.statusBarMetrics.contains(metric)
        return Button {
            settings.toggleStatusMetric(metric)
        } label: {
            Text(metric.shortTitle)
                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(selected ? 0.14 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(selected ? 0.28 : 0.05), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在菜单栏显示 \(metric.title)")
        .accessibilityLabel(metric.title)
        .accessibilityValue(selected ? "已显示" : "已隐藏")
    }

    // MARK: 底部

    private var identityFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(monitor.identity.summary)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("硬件详情") {
                    let url = URL(fileURLWithPath: "/System/Applications/Utilities/System Information.app")
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .font(.system(size: 9))
                .help("打开系统信息 App")
            }
        }
        .padding(.horizontal, 2)
    }
}
