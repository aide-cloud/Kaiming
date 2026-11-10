import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 菜单栏面板「应用」页：已安装应用启动器 + 目录快捷入口 + CLI 提示。
struct AppCenterPanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = AppCenterModel()

    @State private var searchText = ""
    @State private var isChoosingFolder = false
    @State private var hasLoaded = false

    private var filteredApps: [AppCenterModel.InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchField
            folderSection
            appSection
            cliHint
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            model.reload()
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.openInMarkdown(folder: url)
            case .failure(let error):
                appState.flash("选择目录失败：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("应用中心")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Text("\(model.apps.count) 个应用")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("刷新应用列表")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("搜索应用", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    // MARK: - 目录

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("目录")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isChoosingFolder = true
                } label: {
                    Label("打开目录…", systemImage: "folder.badge.plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }

            if model.recentFolders.isEmpty {
                Text("最近没有打开过目录。选择目录后会在 Markdown 窗口展示文件树。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 3) {
                    ForEach(model.recentFolders, id: \.path) { folder in
                        folderRow(folder)
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: URL) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text(folder.lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.openInMarkdown(folder: folder)
        }
        .help(folder.path)
        .padding(.vertical, 2)
    }

    // MARK: - 应用网格

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("已安装应用")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.recentFolders.isEmpty {
                    Button("清除最近目录") {
                        model.forgetRecentFolders()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9))
                }
            }

            if model.isLoading, model.apps.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取应用程序…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if filteredApps.isEmpty {
                Text(searchText.isEmpty ? "没有找到可显示的应用。" : "没有匹配「\(searchText)」的应用。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                    spacing: 6
                ) {
                    ForEach(filteredApps) { app in
                        appButton(app)
                    }
                }
            }
        }
    }

    private func appButton(_ app: AppCenterModel.InstalledApp) -> some View {
        Button {
            model.launch(app)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)

                Text(app.name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .help("启动 \(app.name)")
        .contextMenu {
            Button("启动") { model.launch(app) }
            Button("在 Finder 中显示") { model.reveal(app) }
        }
    }

    private var cliHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("kaiming ./docs")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("在终端运行上述命令，可直接在 Markdown 窗口中打开当前目录（需先安装 CLI，见 README）。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
