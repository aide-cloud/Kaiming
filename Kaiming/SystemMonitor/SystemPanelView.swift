import SwiftUI

// MARK: - 分区

enum SystemSection: String, CaseIterable, Identifiable {
    case clean
    case features
    case uninstall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: "清理释放"
        case .features: "系统功能"
        case .uninstall: "应用卸载"
        }
    }
}

// MARK: - 系统页根视图

/// 菜单栏面板的「系统」页：清理释放 / 系统功能两个分区。
struct SystemPanelView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var section: SystemSection
    private let availableHeight: CGFloat

    init(initialSection: SystemSection = .clean, availableHeight: CGFloat = 0) {
        _section = State(initialValue: initialSection)
        self.availableHeight = availableHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionPicker

            switch section {
            case .clean:
                CleanReleasePane(monitor: monitor)
            case .features:
                SystemFeaturesPane(monitor: monitor)
            case .uninstall:
                AppUninstallPane()
                    .frame(height: max(260, availableHeight - 34), alignment: .top)
            }
        }
        .onAppear {
            monitor.startMonitoring()
            if section == .clean { monitor.scanCachesIfNeeded() }
        }
        .onChange(of: section) { _, newValue in
            if newValue == .clean { monitor.scanCachesIfNeeded() }
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
        .background(
            // 菜单栏面板收起不会销毁视图树：必须靠窗口事件停掉后台采样，
            // 并在重新取得 key 时恢复，否则采样循环会在面板关闭后一直跑。
            PanelVisibilityObserver(
                onVisible: {
                    monitor.startMonitoring()
                    if section == .clean { monitor.scanCachesIfNeeded() }
                },
                onDismiss: {
                    monitor.stopMonitoring()
                }
            )
            .frame(width: 0, height: 0)
        )
    }

    /// 二级分区用下划线文字标签，避免与顶部分段控件叠成两层灰条。
    private var sectionPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(SystemSection.allCases) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { section = item }
                    } label: {
                        VStack(spacing: 5) {
                            Text(item.title)
                                .font(.system(size: 11, weight: section == item ? .semibold : .regular))
                                .foregroundStyle(section == item ? Color.primary : Color.secondary)
                            Capsule(style: .continuous)
                                .fill(section == item ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            Divider()
        }
    }
}

// MARK: - 清理释放

private struct CleanReleasePane: View {
    @ObservedObject var monitor: SystemMonitor
    @EnvironmentObject private var appState: AppState
    /// 面板内内联确认：菜单栏面板里不能用确认弹窗（会把面板 key 抢走并吞掉按钮 action）。
    @State private var isConfirmingClean = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cacheCard
            memoryCard
            appMemoryCard
        }
        .background(
            PanelVisibilityObserver(onDismiss: { isConfirmingClean = false })
                .frame(width: 0, height: 0)
        )
        .onDisappear {
            isConfirmingClean = false
        }
    }

    // MARK: 垃圾清理

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                cacheIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(monitor.cacheScan == nil ? "垃圾清理" : "可清理")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if let scan = monitor.cacheScan {
                            Text(SystemFormat.bytes(scan.totalBytes))
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        } else if monitor.isScanningCaches {
                            Text("扫描中…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(cacheSubtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                cacheActions
            }

            if isConfirmingClean {
                cleanConfirmation
            } else {
                HStack(spacing: 6) {
                    ForEach(CacheKind.allCases) { kind in
                        cacheKindChip(kind)
                    }
                }
                .disabled(monitor.isCleaningCaches)
            }
        }
        .panelCard()
    }

    private var cacheIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SystemPalette.mint.opacity(0.30), SystemPalette.mint.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 40, height: 40)
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SystemPalette.mint)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SystemPalette.mint.opacity(0.25), lineWidth: 1)
        )
    }

    private var cacheSubtitle: String {
        if monitor.isScanningCaches {
            return monitor.cacheScan == nil ? "正在统计用户缓存、日志与废纸篓…" : "正在重新扫描用户缓存、日志与废纸篓…"
        }
        if let scan = monitor.cacheScan {
            let time = scan.scannedAt.formatted(date: .omitted, time: .shortened)
            return "用户缓存 · 日志 · 废纸篓 · 扫描于 \(time)"
        }
        return "统计用户缓存、日志与废纸篓"
    }

    @ViewBuilder
    private var cacheActions: some View {
        if monitor.isCleaningCaches {
            ProgressView()
                .controlSize(.small)
        } else {
            if monitor.isScanningCaches {
                ProgressView()
                    .controlSize(.small)
            } else if monitor.cacheScan != nil {
                Button {
                    monitor.scanCaches()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("重新扫描")
            }
            Button("清理") {
                withAnimation(.easeOut(duration: 0.12)) { isConfirmingClean = true }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(monitor.selectedCacheBytes == 0 || monitor.isScanningCaches)
        }
    }

    private var cleanConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("清理 \(SystemFormat.bytes(monitor.selectedCacheBytes))？")
                        .font(.system(size: 10, weight: .semibold))
                    Text("将删除所选位置的缓存、日志与废纸篓内容；最近 1 小时内修改的文件会保留。此操作不可撤销。")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消") {
                    isConfirmingClean = false
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                Button("清理", role: .destructive) {
                    isConfirmingClean = false
                    Task {
                        let outcome = await monitor.cleanSelectedCaches()
                        if outcome.freedBytes > 0 {
                            appState.flash("已清理 \(SystemFormat.bytes(outcome.freedBytes)) 垃圾", kind: .success)
                        } else {
                            appState.flash("没有清理到内容（部分文件可能正在使用）", kind: .info)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.red.opacity(0.22))
        )
    }

    private func cacheKindChip(_ kind: CacheKind) -> some View {
        let selected = monitor.isSelected(kind)
        let bytes = monitor.cacheScan?.bytes(for: kind)
        return Button {
            monitor.setSelected(!selected, for: kind)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(kind.title)
                    .font(.system(size: 9))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(bytes.map { SystemFormat.bytes($0) } ?? "—")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.06 : 0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(selected ? 0.08 : 0.03), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(selected ? 1 : 0.72)
        .accessibilityLabel("\(kind.title)，\(bytes.map { SystemFormat.bytes($0) } ?? "未扫描")")
        .accessibilityValue(selected ? "已选择" : "未选择")
    }

    // MARK: 内存

    private var memoryCard: some View {
        let memory = monitor.memory
        let tint = SystemPalette.pressure(memory.pressure)
        let total = max(memory.totalBytes, 1)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("内存占用")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(memory.usedPercent)%")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("已用 \(SystemFormat.bytes(memory.usedBytes)) / \(SystemFormat.bytes(memory.totalBytes))")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 4)
                releaseButton
            }

            StackedMemoryMeter(
                segments: [
                    MemoryMeterSegment(id: "app", fraction: Double(memory.appBytes) / Double(total), color: SystemPalette.mint),
                    MemoryMeterSegment(id: "wired", fraction: Double(memory.wiredBytes) / Double(total), color: SystemPalette.amber),
                    MemoryMeterSegment(id: "compressed", fraction: Double(memory.compressedBytes) / Double(total), color: SystemPalette.violet),
                ]
            )

            HStack(spacing: 10) {
                LegendDot(color: SystemPalette.mint, text: "应用 \(SystemFormat.bytes(memory.appBytes))")
                LegendDot(color: SystemPalette.amber, text: "联动 \(SystemFormat.bytes(memory.wiredBytes))")
                LegendDot(color: SystemPalette.violet, text: "压缩 \(SystemFormat.bytes(memory.compressedBytes))")
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                Text("内存压力 \(memory.pressure.title)")
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                Text("· 可回收约 \(SystemFormat.bytes(memory.reclaimableBytes))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if memory.swapUsedBytes > 0 {
                    Text("交换 \(SystemFormat.bytes(memory.swapUsedBytes))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .help("可回收 = 闲置页 + 可清除页的估算；实际释放量以释放前后的采样差值为准")
        }
        .panelCard()
    }

    @ViewBuilder
    private var releaseButton: some View {
        if monitor.isReleasingMemory {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("释放中")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("释放") {
                Task {
                    let result = await monitor.releaseMemory()
                    if result.freedBytes > 0 {
                        appState.flash("已释放 \(SystemFormat.bytes(result.freedBytes)) 内存", kind: .success)
                    } else {
                        appState.flash("已请求系统回收闲置内存，当前采样没有明显下降", kind: .info)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("申请并立即归还一次性大内存，促使系统回收闲置页")
        }
    }

    // MARK: 应用内存

    private var appMemoryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("应用内存")
                    .font(.system(size: 10, weight: .semibold))
                Text("按应用聚合")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if monitor.memory.totalBytes > 0 {
                    Text("物理内存 footprint")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            if monitor.apps.isEmpty {
                Text("正在读取进程…")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(monitor.apps) { row in
                    appRow(row)
                }
            }
        }
        .panelCard()
    }

    private func appRow(_ row: AppMemoryRow) -> some View {
        HStack(spacing: 7) {
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 11))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }
            Text(row.name)
                .font(.system(size: 10))
                .foregroundStyle(row.isOther ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(SystemFormat.bytes(row.bytes))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(row.isOther ? .tertiary : .secondary)
        }
        .frame(height: 19)
        .accessibilityElement(children: .combine)
    }
}
