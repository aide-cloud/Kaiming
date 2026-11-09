# 第三方代码内嵌说明（Vendor）

Kaiming 的 Markdown 模块使用原生 TextKit 2 渲染，第三方代码全部集中在
`MarkdownKit/`，**不依赖网络、不依赖 SwiftPM**，保证工程可以离线复现构建。

## 为什么内嵌而不是 Swift Package

按原始技术选型验证了两条路径：

1. **首选 `contexthub-dev/swift-markdown-editor` 0.1.0**：在本机 Xcode 16.2 / Swift 6.0.3
   工具链下编译失败（源码使用了更高版本工具链才有的 `isolated deinit`，并且存在多处
   Sendable 检查错误）。结论：当前工具链不可用，按规格降级。
2. **备选 `nodes-app/swift-markdown-engine` 0.15.0**：用 `swift build` 可以完整编译通过；
   但 Xcode 16 的 SwiftPM 把 manifest 缓存固定在 `~/Library/Caches/org.swift.swiftpm`，
   与当前构建 Sandbox 冲突，`xcodebuild` 无法完成依赖解析。
3. 为保证工程在任意环境（包括受限 Sandbox / CI 离线环境）可构建，将 0.15.0 源码以
   **固定 commit 快照**方式内嵌。升级时按下方「升级步骤」整体替换源码并重新应用补丁。

## 固定版本

| 组件 | 上游 | 版本 / commit | 许可证 | 内嵌位置 |
|---|---|---|---|---|
| swift-markdown-engine | https://github.com/nodes-app/swift-markdown-engine | `0.15.0` / `f762ab7ec17472e6d3f3b652b97c747e507c66ec` | Apache-2.0 | `MarkdownKit/MarkdownEngine/`、`MarkdownEngineCodeBlocks/`、`MarkdownEngineLatex/`（由 `MarkdownEngine` framework target 编译，Swift 5 模式） |
| SwiftMath | https://github.com/mgriebling/SwiftMath | `1.7.3` / `fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7` | MIT | `MarkdownKit/SwiftMath/` |
| highlight.js | https://highlightjs.org | 随 MarkdownEngineCodeBlocks 0.15.0 分发 | BSD-3-Clause | `Kaiming/Resources/Markdown/highlight.min.js` |

许可证文本保留在 `docs/licenses/`：`LICENSE-MarkdownEngine.txt`、`LICENSE-SwiftMath.txt`、
`highlight.js-LICENSE.txt`。

## 为内嵌做的补丁（共 5 处，均为机械替换）

1. `MarkdownEngineCodeBlocks/HighlightJSBridge.swift`
   - 移除 `import MarkdownEngine`（同 target 内嵌后不再需要模块导入）。
   - `Bundle.module` → `Bundle.main`（highlight.min.js 由 app 资源提供）。
2. `SwiftMath/MathBundle/MathFont.swift`（2 处）
   - `Bundle.module` → `Bundle.main`（`mathFonts.bundle` 随 app 资源提供）。
3. `SwiftMath/MathRender/MTFont.swift`（1 处）
   - `Bundle.module` → `Bundle.main`。
4. `MarkdownEngineLatex/SwiftMathBridge.swift`
   - 移除 `import SwiftMath`、`import MarkdownEngine`。
5. 删除 `MarkdownEngine.docc/`（DocC 目录，不参与运行，避免 app target 触发文档编译）
   与重复的许可证副本（Xcode 资源拷贝重名会直接构建失败）。

## 升级步骤

```bash
cd /tmp && git clone --depth 1 --branch <version> https://github.com/nodes-app/swift-markdown-engine.git
# 用 Sources/ 覆盖 MarkdownKit/ 对应目录，重新应用上面 5 处补丁
# 同步更新本文件的版本与 commit，并重新跑构建 + Markdown 冒烟测试
```

## 资源打包验证

构建后 `Kaiming.app/Contents/Resources/` 必须包含：

- `highlight.min.js`
- `mathFonts.bundle/`（含 `.otf` 数学字体）
- `MarkdownEngine.framework`（`Contents/Frameworks/`，随 app 嵌入）

缺失时 Markdown 代码高亮 / LaTeX 会降级为纯文本，不会崩溃。
