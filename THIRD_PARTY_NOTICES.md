# 第三方组件声明

Kaiming 内嵌以下第三方源码/资源。完整许可证文本见 `docs/licenses/`。

## swift-markdown-engine 0.15.0

- 上游：https://github.com/nodes-app/swift-markdown-engine
- 固定 commit：`f762ab7ec17472e6d3f3b652b97c747e507c66ec`
- 许可：Apache License 2.0
- 用途：TextKit 2 原生 Markdown 编辑器（`MarkdownEngine` framework target）
- 修改：仅 5 处资源/模块导入的机械替换，详见 `docs/vendor.md`

## SwiftMath 1.7.3

- 上游：https://github.com/mgriebling/SwiftMath
- 固定 commit：`fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7`
- 许可：MIT
- 用途：Markdown 内联/块级 LaTeX 渲染（经 swift-markdown-engine 的 `SwiftMathBridge`）
- 修改：3 处 `Bundle.module` → `Bundle.main`

## Mermaid 11.17.2

- 上游：https://github.com/mermaid-js/mermaid
- 版本：11.17.2（UMD / `mermaid.min.js`）
- 许可：MIT
- 用途：Markdown 渲染预览中的 ```mermaid 图表离线渲染
  （`Kaiming/Resources/Markdown/mermaid.min.js`，随 app bundle 分发，不联网）
- 修改：无；仅拷贝上游 dist 文件
- 主题：参考 Crescent 的 `mermaid-theme.ts` 风格（深色画布、青绿 accent #13C2C2、
  节点圆角 7、虚线流动边），通过 `themeVariables` / `themeCSS` 注入，不改动库源码

## highlight.js

- 上游：https://highlightjs.org
- 随 swift-markdown-engine 0.15.0 的 `MarkdownEngineCodeBlocks` 分发
- 许可：BSD-3-Clause
- 用途：代码块语法高亮（`Kaiming/Resources/Markdown/highlight.min.js`）

## Apple 框架

ScreenCaptureKit、AppKit、SwiftUI、TextKit 2、Carbon、ServiceManagement 等为 Apple 系统框架，
遵循 macOS SDK 许可。
