import AppKit
import SwiftUI

/// 系统页的「应用卸载」分区：选择应用 → 扫描关联文件 → 确认后卸载。
///
/// 面板内不使用系统弹窗（会收起菜单栏面板），确认全部做成内联卡片。
struct AppUninstallPane: View {
    @StateObject private var model = AppUninstallModel()
    @EnvironmentObject private var appState: AppState
    @State private var isConfirming = false

    var body: some View {
        Group {
            if let selected = model.selected {
                detailView(selected)
            } else {
                pickerView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.loadAppsIfNeeded()
            #if DEBUG
            autoSelectForSnapshotIfNeeded()
            #endif
        }
        .onChange(of: model.selected?.id) { _, _ in
            isConfirming = false
        }
        .background(
            PanelVisibilityObserver(onDismiss: { isConfirming = false })
                .frame(width: 0, height: 0)
        )
    }

    #if DEBUG
    /// 调试快照：`KAIMING_UNINSTALL_SELECT=应用名/ bundle id` 自动进入详情页。
    private func autoSelectForSnapshotIfNeeded() {
        guard let needle = ProcessInfo.processInfo.environment["KAIMING_UNINSTALL_SELECT"],
              !needle.isEmpty else { return }
        NSLog("Kaiming debug: uninstall auto-select needle=\(needle)")
        Task {
            for _ in 0..<60 {
                if let row = model.apps.first(where: {
                    $0.app.name.localizedCaseInsensitiveContains(needle)
                        || $0.app.bundleID.localizedCaseInsensitiveContains(needle)
                }) {
                    NSLog("Kaiming debug: uninstall auto-select found \(row.app.name)")
                    model.select(row)
                    if ProcessInfo.processInfo.environment["KAIMING_UNINSTALL_CONFIRM"] == "1" {
                        for _ in 0..<80 {
                            if !model.isScanning, !model.items.isEmpty {
                                isConfirming = true
                                return
                            }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    #endif

    // MARK: - 应用列表

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField

            HStack(spacing: 4) {
                Text("已安装应用")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(model.filteredApps.count)")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Image(systemName: "info.circle")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .help("仅列出 /Applications 与 ~/Applications 下的第三方应用；Apple 系统应用与开明自身已隐藏。卸载不可撤销。")
                Spacer(minLength: 4)
                Button {
                    model.reloadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("重新扫描已安装应用")
                .disabled(model.isLoading)
            }

            appList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索应用", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var appList: some View {
        if model.isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在扫描应用…")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cardBackground)
        } else if model.filteredApps.isEmpty {
            Text(model.query.isEmpty ? "没有可卸载的第三方应用" : "没有匹配的应用")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(cardBackground)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.filteredApps.enumerated()), id: \.element.id) { index, row in
                        appRow(row)
                        if index < model.filteredApps.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: .infinity)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func appRow(_ row: AppUninstallRow) -> some View {
        Button {
            model.select(row)
        } label: {
            HStack(spacing: 8) {
                if let icon = row.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 12))
                        .frame(width: 20, height: 20)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(row.app.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        if row.isRunning {
                            runningBadge
                        }
                    }
                    Text(row.app.bundleID)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 详情 / 卸载

    private func detailView(_ selected: AppUninstallRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    model.clearSelection()
                } label: {
                    Label("应用列表", systemImage: "chevron.left")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .disabled(model.isRemoving)
                Spacer(minLength: 4)
                Button {
                    model.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("重新扫描关联文件")
                .disabled(model.isScanning || model.isRemoving)
            }

            HStack(spacing: 8) {
                if let icon = selected.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(selected.app.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if selected.isRunning { runningBadge }
                    }
                    Text(subtitle(for: selected.app))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if model.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描关联文件…")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在刷新应用列表…")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 4) {
                    Text("将删除 \(model.items.count) 项 · \(SystemFormat.bytes(model.totalBytes))")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(model.checkedIDs.count >= model.items.count ? "全不选" : "全选") {
                        model.setAllChecked(model.checkedIDs.count < model.items.count)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 8))
                    .disabled(model.isRemoving)
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            itemRow(item)
                        }
                    }
                }
                .frame(
                    minHeight: min(150, max(29, CGFloat(model.items.count) * 27)),
                    maxHeight: .infinity
                )
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionArea(selected)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func itemRow(_ item: UninstallItem) -> some View {
        HStack(spacing: 5) {
            if item.category == .app {
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
                    .frame(width: 12)
                    .help("应用本体必须随卸载删除")
            } else {
                Button {
                    model.toggle(item)
                } label: {
                    Image(systemName: model.isChecked(item) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10))
                        .foregroundStyle(model.isChecked(item) ? Color.accentColor : Color.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .disabled(model.isRemoving)
            }

            Image(systemName: item.category.symbolName)
                .font(.system(size: 8))
                .frame(width: 12)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 9))
                    .lineLimit(1)
                Text(itemSubtitle(item))
                    .font(.system(size: 7))
                    .foregroundStyle(item.category == .userData ? Color.orange.opacity(0.85) : Color.secondary.opacity(0.7))
            }

            Spacer(minLength: 4)
            Text(SystemFormat.bytes(item.bytes))
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .frame(height: 27)
        .contentShape(Rectangle())
        .help(item.url.path)
    }

    private func itemSubtitle(_ item: UninstallItem) -> String {
        switch item.category {
        case .app: "应用本体 · 必须删除"
        case .userData: "用户目录 · 请确认不是个人文件"
        default: item.category.title
        }
    }

    @ViewBuilder
    private func actionArea(_ selected: AppUninstallRow) -> some View {
        if model.isRemoving {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在退出并删除…")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 24)
        } else if isConfirming {
            confirmationCard(selected)
        } else {
            Button(role: .destructive) {
                isConfirming = true
            } label: {
                Label("卸载并删除 \(SystemFormat.bytes(model.checkedBytes))", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .disabled(model.checkedBytes == 0)
        }
    }

    private func confirmationCard(_ selected: AppUninstallRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("卸载 \(selected.app.name) 并删除 \(SystemFormat.bytes(model.checkedBytes))？")
                        .font(.system(size: 10, weight: .semibold))
                    Text("将先退出应用（请先保存应用内未保存的内容），再删除应用本体与勾选的关联文件（共 \(model.checkedItems.count) 项，含应用本体）。部分受系统保护的目录可能需要完全磁盘访问权限；此操作不可撤销。")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.checkedItems.contains(where: { $0.category == .userData }) {
                        Text("包含用户目录中的同名文件（可能含个人资料），请确认。")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消") { isConfirming = false }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("确认卸载", role: .destructive) {
                    isConfirming = false
                    performUninstall()
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

    private func performUninstall() {
        Task {
            guard let outcome = await model.uninstall() else {
                if let error = model.errorMessage {
                    appState.flash(error, kind: .error)
                }
                return
            }
            if outcome.failures.isEmpty {
                appState.flash("已卸载并删除 \(SystemFormat.bytes(outcome.freedBytes))", kind: .success)
            } else {
                Log.system.error("Uninstall failures: \(outcome.failures.joined(separator: " | "), privacy: .public)")
                appState.flash("已卸载；\(outcome.failures.count) 项删除失败（已记录日志）", kind: .error)
            }
        }
    }

    // MARK: - 工具

    private var runningBadge: some View {
        Text("运行中")
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }

    private func subtitle(for app: InstalledApp) -> String {
        var parts: [String] = []
        if let version = app.version, !version.isEmpty {
            parts.append("v\(version)")
        }
        parts.append(app.bundleID)
        return parts.joined(separator: " · ")
    }
}
