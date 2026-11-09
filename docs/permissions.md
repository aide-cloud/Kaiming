# 权限说明

## 屏幕录制（Screen Recording）

截图使用 ScreenCaptureKit（macOS 14+），它受 macOS TCC 的「屏幕录制」权限控制。

### 授权步骤

1. 首次触发截图（快捷键或面板按钮）时，Kaiming 检查 `CGPreflightScreenCaptureAccess()`。
2. 未授权时点「请求权限」会调用 `CGRequestScreenCaptureAccess()`；系统可能只弹一次。
3. 打开 **系统设置 → 隐私与安全性 → 屏幕录制**，勾选 **Kaiming**。
4. **退出并重新打开 Kaiming**。TCC 的授权对已运行进程不会立即刷新。

### 为什么必须显式检查

ScreenCaptureKit 在未授权时：

- `SCShareableContent.excludingDesktopWindows(...)` 返回 **空列表**；
- 不抛错、不弹系统提示。

如果不处理空列表，用户会看到"点了没反应"。Kaiming 的处理：

- `ScreenCapturePermission.isGranted` 预检；
- `SCShareableContent` 的 `displays.isEmpty` 同样视为权限缺失；
- 面板顶部横幅 + `AppState.flash` 文案 + 打开系统设置按钮；
- 日志记录（`Log.screenshot`）。

### Info.plist

`Config/Info.plist` 包含：

```xml
<key>NSScreenCaptureUsageDescription</key>
<string>Kaiming 需要屏幕录制权限来截取屏幕内容。截图仅在本机处理，不会上传到任何服务器。</string>
```

TCC 使用应用签名身份（CFBundleIdentifier + 团队 ID / 路径）记忆授权。**重新签名或换路径后
系统可能要求重新授权**，这是 macOS 行为。

## 壁纸

`NSWorkspace.setDesktopImageURL(_:for:options:)` 不需要 TCC 弹窗，但：

- 必须在主线程调用；
- 目标文件必须长期存在且可读（Kaiming 复制到 `Application Support/Kaiming/Wallpapers`）；
- 沙盒应用可能因系统壁纸服务无法读取容器内文件而失败。本项目 Developer ID 构建默认关闭
  App Sandbox（见分发文档）；若启用沙盒，建议把壁纸目录换成用户选择的 `~/Pictures` 子目录。

## 剪贴板

- 读取 `NSPasteboard.general` 不需要 TCC 弹窗，但 macOS 15+ 可能在后台读取时显示系统提示。
- 本实现只在 `changeCount` 变化时读取内容，并用类型检查避免无意义读取。
- 所有访问走串行队列，避免并发崩溃。

## 登录项

设置 → 通用 → 「登录时自动启动」使用 `SMAppService.mainApp`：

- 已签名的 app 正常注册；
- ad-hoc / 未签名开发构建可能返回权限错误，设置页会展示系统错误文本，不会静默失败。

## 数据与隐私

- 截图、剪贴板、壁纸、Markdown 内容全部只在本机读写。
- 不包含任何网络请求代码。
- 日志使用 `os.Logger`，不含剪贴板正文/截图内容。
