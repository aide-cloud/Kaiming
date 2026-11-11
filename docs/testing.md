# 测试与验收

## 0. 自动化构建

```bash
./Scripts/build.sh
```

期望：`** BUILD SUCCEEDED **`，无 Swift error。

静态自查（CI 可执行）：

```bash
grep -rn "TODO\|FIXME\|fatalError(\"unimplemented" Kaiming --include='*.swift' | grep -v Vendor || true
grep -rn "WKWebView\|WebKit" Kaiming --include='*.swift' || true          # 必须为空
grep -rn "CGWindowListCreateImage" Kaiming --include='*.swift' || true    # 不允许旧截图 API
grep -rn "captureScreenshot" Kaiming --include='*.swift' || true          # 不允许 macOS 26 专属 API
```

## 1. 启动

- [ ] `open build/dd/Build/Products/Debug/Kaiming.app` 后进程存活。
- [ ] 菜单栏出现取景器图标；Dock 无图标（`LSUIElement`）。
- [ ] 启动时**不**自动弹出 Markdown 窗口。
- [ ] 菜单栏图标点击弹出 400×580 面板，四个 Tab（截图/剪贴板/壁纸/应用）可切换。
- [ ] 点面板右上 Markdown 图标打开独立窗口；关闭后可再次打开。
- [ ] 设置窗口可打开（面板底部齿轮 / ⌘,）。

调试构建提供以下验证钩子（Release 不包含；见 `#if DEBUG`）：

```bash
APP=build/dd/Build/Products/Debug/Kaiming.app
"$APP/Contents/MacOS/Kaiming" --open-markdown          # 打开 Markdown 窗口
"$APP/Contents/MacOS/Kaiming" --open-settings          # 打开设置窗口
"$APP/Contents/MacOS/Kaiming" --open-clipboard         # 打开剪贴板快捷选择窗口
"$APP/Contents/MacOS/Kaiming" --open-folder /abs/path  # 模拟 CLI 打开目录树
"$APP/Contents/MacOS/Kaiming" --snapshot-panel /tmp/panel.png [--snapshot-tab clipboard|wallpaper|apps] [--snapshot-fake-capture]
# --snapshot-fake-capture 用合成图片填充“刚截取的画面”快捷条，便于无 TCC 权限时验收
"$APP/Contents/MacOS/Kaiming" --snapshot-clipboard-picker /tmp/picker.png
"$APP/Contents/MacOS/Kaiming" --snapshot-markdown /tmp/markdown.png
"$APP/Contents/MacOS/Kaiming" --snapshot-settings /tmp/settings.png
"$APP/Contents/MacOS/Kaiming" --capture-test full      # 真实全屏截图（本次覆盖不复制，不改持久化设置）
"$APP/Contents/MacOS/Kaiming" --capture-test full --capture-test-copy  # 显式验证截图→剪贴板链路
```

`--snapshot-*` 在进程内用真实 `NSWindow + NSHostingView` 渲染，不依赖屏幕录制权限。

验证命令：

```bash
lsappinfo list | grep -A3 Kaiming      # 应显示 type="UIElement"
log show --info --debug --last 5m --predicate 'subsystem == "com.kaiming.app"' --style compact
```

## 2. 屏幕录制权限

- [ ] 未授权时：面板顶部橙色横幅，截图入口给出明确提示，不静默。
- [ ] 点「请求权限」出现系统流程；「打开系统设置」跳到 隐私与安全性 → 屏幕录制。
- [ ] 授权后**重启应用**，横幅消失，截图可用。
- [ ] 撤销权限（`tccutil reset ScreenCapture com.kaiming.app`）后重启，横幅重新出现。
- [ ] 已授权但 `CGPreflightScreenCaptureAccess()` 返回 false 时，截图仍按真实 SCK 结果工作（不再假阳性拦截）。
- [ ] 实际 SCK 失败时弹出恢复面板：重启应用 / 打开系统设置 / 取消；设置页「重置屏幕录制权限…」可清除旧 TCC 记录。

## 3. 截图

### 区域
- [ ] ⌥⇧S 或面板按钮进入覆盖层；每块显示器都被覆盖。
- [ ] 拖拽出现选区 + 尺寸标签；8 个手柄都能调整；选区不能拖出屏幕。
- [ ] Esc 取消且清理所有窗口；Return/双击确认。
- [ ] 确认后图片进入剪贴板（粘贴到备忘录验证）。
- [ ] Retina/4K 屏截图输出为原生像素（本机 3840×2160，不是 1920×1080）。
- [ ] 多显示器：在副屏框选，裁剪坐标正确。

### 窗口
- [ ] ⌥⇧W 后鼠标悬停高亮单个窗口；点击只截该窗口，不带背景。
- [ ] 本应用自己的窗口/菜单栏不会被选中。

### 全屏
- [ ] ⌥⇧F 截取鼠标所在屏幕，无覆盖层，直接完成。

### 标注与后处理
- [ ] 矩形、箭头、文字、颜色、撤销可用，标注位置与最终图一致。
- [ ] 设置「自动复制到剪贴板」关闭后，不再写剪贴板。
- [ ] 设置「自动保存到文件夹」开启后，文件出现在所选目录。
- [ ] 每次截图都在 `~/Library/Application Support/Kaiming/Captures/` 留档；超过 30 张后最旧被清理。
- [ ] 截图声音开关生效；面板显示最近截图缩略图与「刚截取的画面」快捷条。
- [ ] 快捷条：复制到剪贴板、保存副本到截图文件夹、直接设为壁纸、收起；四个动作都有成功/失败提示。
- [ ] 连续快速触发不会叠加多套覆盖层。

## 4. 剪贴板

- [ ] 复制一段文本 → 面板历史出现新记录，类型为文本。
- [ ] 复制图片（截图/预览）→ 历史出现缩略图，图片文件在 `Application Support/Kaiming/Clipboard/`。
- [ ] Finder 复制文件 → 类型为文件 URL，复制按钮能把文件放回剪贴板。
- [ ] 相同内容连续复制不重复入栈。
- [ ] 置顶项在超过上限后仍保留；取消置顶后恢复淘汰规则。
- [ ] 删除单项同时删除对应图片文件；清空历史后列表为空。
- [ ] 关闭「监控剪贴板变化」后不再新增；重新开启后恢复。
- [ ] 在面板点复制不会产生重复历史（自身写入被基线跳过）。
- [ ] 并发压测：快速 pbcopy 循环时无崩溃（串行队列生效）。

## 5. 壁纸

- [ ] 面板列出所有显示器、主屏标记正确。
- [ ] 从剪贴板设置壁纸：桌面立即变化；文件出现在 `Application Support/Kaiming/Wallpapers/`。
- [ ] 从图片文件设置：源文件删除后壁纸仍保持（已复制持久化）。
- [ ] 壁纸页不展示「最近截图」；来源只有剪贴板/选择图片/视频。
- [ ] 多显示器：只勾选副屏时只改副屏。
- [ ] 退出并重启应用、再重启 Mac 后壁纸仍保持。
- [ ] 无剪贴板图片/坏图片时给出错误提示，不崩溃。

## 6. Markdown

- [ ] 从面板打开 Markdown 窗口，欢迎文档正常渲染（标题、列表、代码块、表格、公式）。
- [ ] 输入 `**粗体**`、`# 标题` 等，光标离开后实时渲染；光标进入元素显示源码。
- [ ] 代码块有语法高亮；`$E=mc^2$` / `$$...$$` 公式渲染。
- [ ] 「从剪贴板载入」把剪贴板文本放入编辑器（不覆盖未保存内容时不提示视为缺陷）。
- [ ] 打开本地 `.md` 成功；保存并重新打开内容一致。
- [ ] 未命名文档保存时弹出保存面板，扩展名 `.md`。
- [ ] 复制按钮把 Markdown 源码放回剪贴板。
- [ ] 字号 +/- 生效并在重启后保持。
- [ ] 未保存修改时新建/打开有确认。
- [ ] 超长文档滚动/输入无明显卡顿。
- [ ] 本地图片（相对/绝对路径）、远程图片渲染；缺失图片保留源码。
- [ ] 内部链接（相对 .md/文本/图片）在应用内打开；外部 http(s) 浏览器打开。
- [ ] 富内容 inspector：外链卡片标题/域名/描述、HTML 块原生渲染（非源码）；无 WebView。
- [ ] 开 inspector 时编辑/脏文档保护/保存不回归。
- [ ] 工具栏图标 hover 260ms 显示文字提示（新建/保存/打开文件夹/预览等全部）。
- [ ] 点击内部链接打开新文档后，侧栏展开其父目录、其他目录收起；项目外文件只打开不改树。
- [ ] 右侧内容导航显示标题大纲，点击滚动到对应标题。
- [ ] 含 HTML 的文档出现一键「渲染预览」；HTML `<img>` 相对/绝对/http 图片可见，不显示原始标签。
- [ ] 渲染预览只读，切回编辑不丢未保存内容。

## 7. 快捷键与设置

- [ ] ⌥⇧S / W / F / M 全部生效（应用在后台时）。
- [ ] 设置页显示快捷键；注册失败（被占用）时有橙色说明。
- [ ] 关闭全局快捷键后全部失效；重新开启后恢复，无需重启。
- [ ] 所有设置项重启后保持。
- [ ] 「登录时自动启动」在签名构建上可注册/注销；失败时显示系统错误。
- [ ] 「恢复默认设置」清空自定义值并重新注册快捷键。

## 8. 分发

- [ ] `./Scripts/archive.sh` 生成 `.xcarchive`、`build/export/Kaiming.app`、DMG。
- [ ] Developer ID 构建：`codesign --verify --deep --strict` 通过。
- [ ] 公证：`./Scripts/notarize.sh` 成功，`spctl --assess` 为 accepted。
- [ ] 干净机器首次打开无「无法验证开发者」提示。

## 9. 交付标准对照

| 规格 | 验收点 |
|---|---|
| 1 菜单栏常驻、无 Dock | 1 启动 |
| 2 三种截图 + 标注 + 自动进剪贴板 | 3 全部 |
| 3 剪贴板类型/历史/复制/清除 | 4 全部 |
| 4 壁纸多源/多屏/重启保持 | 5 全部 |
| 5 Markdown 独立窗口/载入/编辑/预览/保存 | 6 全部 |
| 6 同一工程共享权限与设置 | 工程结构 + 1/7 |
| 7 首次权限引导 | 2 全部 |
| 8 可签名公证 | 8 全部 |

## 10. v1.1 新功能验收

### 剪贴板快捷选择
- [ ] ⌥⇧C 在后台唤起 520×460 选择窗口，搜索框自动聚焦。
- [ ] ↑/↓ 移动、Return 复制并关闭、Esc 关闭；中文输入法组合期间不抢键。
- [ ] 搜索过滤文本/文件名/类型；空历史与无结果有提示；置顶标记正确。
- [ ] 面板剪贴板页的「⌥⇧C」按钮可打开同一窗口。

### Markdown 目录树 / CLI
- [ ] 工具栏「打开文件夹…」选择目录后侧边栏显示文件树，文件夹优先，只有 `.md/.markdown`。
- [ ] 点击文件载入、当前文件高亮、展开/折叠、刷新、侧边栏隐藏/显示。
- [ ] 外部打开：`./Scripts/kaiming ./docs` 或 `--open-folder "$PWD/docs"` 打开目录树。
- [ ] 「打开项目文件夹…」选择任意项目根，默认「全部文件」，文件夹/文件带类型图标。
- [ ] 点击 `.md` 正常编辑；点击 `.txt/.swift/.json` 显示只读纯文本预览；图片/二进制不崩溃。
- [ ] 脏 Markdown 下预览其他文件不会丢失未保存内容；切回/载入 .md 仍有确认。
- [ ] 脏文档时仅切目录不弹确认；载入文件前弹确认，取消后内容保留。
- [ ] `./Scripts/install-cli.sh` 后 `kaiming ./docs` 冷启动/热启动均能打开。

### 应用中心
- [ ] 「应用」tab 显示已安装应用图标网格、数量、搜索；点击可启动；右键可在 Finder 显示。
- [ ] 「打开目录…」跳转 Markdown 目录树；最近目录可点击复用并可清除。
- [ ] 88+ 应用时滚动流畅；刷新不卡主线程。

### 视频动态壁纸
- [ ] 壁纸页切换「视频」，点「选择视频…」后 NSOpenPanel 保持打开，popover 关闭不会取消；选中 MP4/MOV 后显示首帧、时长、分辨率。
- [ ] 图片/轮换文件夹选择同样不会被 popover 关闭取消。
- [ ] 启用后桌面层窗口出现（level = desktopWindow+1，覆盖 screen.frame），循环静音播放；桌面图标仍在视频上方。
- [ ] 菜单栏背景使用视频首帧 poster 匹配（系统限制：菜单栏不能播放视频）；停止后恢复原系统壁纸。
- [ ] 停止后窗口消失；退出 App 后停止；重启 App 恢复上次启用状态。
- [ ] 应用静态壁纸会停止对应屏动态壁纸；无系统「视频壁纸」API 的说明可见。

### 截图圆角 / 长截图
- [ ] 圆角 0–48pt 可调，预览与导出 PNG 一致，圆角外透明。
- [ ] 区域长截图：点击后**直接进入手动滚动**，选区边框持续可见；用户滚动实时页面，HUD 显示采集进度。
- [ ] HUD「自动滚动」：未授权辅助功能时提示并保持手动；授权后自动滚动并与已拼接内容连续。
- [ ] 完成/取消/自动无变化/手动长时间无变化/20000px 上限均正确停止并进入预览确认。
- [ ] 拼接结果无重复内容/无断裂；无变化、超过 20000px、Esc 取消均正确提示。
- [ ] 长截图结果进入预览确认，之后正常写剪贴板/历史/自动保存。
