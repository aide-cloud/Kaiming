# GitHub Actions 打包

工作流：[`.github/workflows/package.yml`](../.github/workflows/package.yml)

## 触发方式

| 事件 | 行为 |
|---|---|
| push 到 `main` | 构建 → 打包 → 上传 artifact |
| push tag `v*` | 构建 → 打包 → 上传 artifact → 自动创建/更新 GitHub Release |
| pull request | 构建 → 打包 → 上传 artifact（不发布 Release） |
| 手动 `workflow_dispatch` | 同上，可在 Actions 页面运行 |

## Runner 与工具链

- `macos-15`（Apple Silicon runner）
- 自动选择 `/Applications/Xcode_16*.app` 中最新的 Xcode；要求 Xcode 16+
- `UNIVERSAL=1`：同时构建 `arm64` 与 `x86_64`，产物为通用二进制
- 无需 Apple 证书；使用 **ad-hoc 签名**，Hardened Runtime 关闭（与本地归档一致）

## 产物

Artifact 名称：`Kaiming-<commit-sha>`，内容在 `build/dist/`：

- `Kaiming-<version>.zip`（app 压缩包）
- `Kaiming-<version>.dmg`（拖拽安装镜像，含 `/Applications` 快捷方式）
- `SHA256SUMS.txt`

tag 构建会把这些文件附加到对应 Release。

下载：GitHub → Actions → 对应 run → Artifacts。

## 签名与公证

CI 产物是 ad-hoc 签名，未经过 Apple 公证。首次打开可能触发 Gatekeeper 警告；正式分发请：

1. 使用 Developer ID 证书在本机运行 `./Scripts/archive.sh --sign`；
2. 运行 `./Scripts/notarize.sh build/export/Kaiming.app`；
3. 或在本工作流中扩展签名步骤：导入 `SIGNING_CERTIFICATE_P12` 到临时 keychain，
   设置 `DEVELOPMENT_TEAM`、`CODE_SIGN_IDENTITY="Developer ID Application"`、
   `ENABLE_HARDENED_RUNTIME=YES`，再调用 notarytool 与 stapler。

详见 [distribution.md](distribution.md)。

## 本地复现 CI 打包

```bash
# 通用二进制 Release 归档（ad-hoc）
UNIVERSAL=1 ./Scripts/archive.sh

# ZIP + DMG + SHA256SUMS
./Scripts/package.sh build/export/Kaiming.app build/dist

# 受限沙箱/无 DMG 环境下只验证 ZIP
SKIP_DMG=1 ./Scripts/package.sh build/export/Kaiming.app build/dist
```

`archive.sh` 在受限沙箱下可能无法创建 DMG（`hdiutil` 挂载被拒），脚本会保留
`build/export/Kaiming.app` 并继续；GitHub macOS runner 不受此限制。
