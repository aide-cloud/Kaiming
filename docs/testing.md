# 测试与验收

## 0. 自动化构建

```bash
./Scripts/build.sh
```

期望：`** BUILD SUCCEEDED **`，无 Swift error。

静态自查（CI 可执行）：

```bash
grep -rn "TODO\|FIXME\|fatalError(\"unimplemented" Kaiming --include='*.swift' | grep -v Vendor || true
grep -rn "WKWebView\|WebKit" Kaiming --include='*.swift' || true          # 仅 Markdown 渲染预览 / PDF 导出允许出现
grep -rn "CGWindowListCreateImage" Kaiming --include='*.swift' || true    # 不允许旧截图 API
grep -rn "captureScreenshot" Kaiming --include='*.swift' || true          # 不允许 macOS 26 专属 API
grep -rn "CGDisplayCreateImage" Kaiming --include='*.swift'               # 仅允许 SCK 缺失显示器时的兜底
```

## 1. 启动

- [ ] `open build/dd/Build/Products/Debug/Kaiming.app` 后进程存活。
- [ ] 菜单栏出现开明兽（Mono 线稿）图标；Dock 无图标（`LSUIElement`）。
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
"$APP/Contents/MacOS/Kaiming" --snapshot-panel /tmp/panel.png [--snapshot-tab clipboard|wallpaper|apps] [--snapshot-fake-capture] [--snapshot-clipboard-scope live|favorites]
# --snapshot-fake-capture 用合成图片填充“刚截取的画面”快捷条，便于无 TCC 权限时验收
# --snapshot-clipboard-scope 让剪贴板页直接渲染「收藏」或「实时」分区
"$APP/Contents/MacOS/Kaiming" --snapshot-clipboard-picker /tmp/picker.png [--snapshot-clipboard-scope live|favorites]
# 截图想用固定样例、不动真实历史时：KAIMING_SUPPORT_DIR=/tmp/kaiming-support 指向临时数据目录（仅 DEBUG 生效）
"$APP/Contents/MacOS/Kaiming" --snapshot-markdown /tmp/markdown.png
"$APP/Contents/MacOS/Kaiming" --snapshot-markdown /tmp/find.png --markdown-find [--markdown-find-query 词] [--markdown-find-regex] [--markdown-find-replacement 词] [--markdown-find-replace-all]
"$APP/Contents/MacOS/Kaiming" --snapshot-markdown /tmp/preview-find.png --markdown-render-preview --markdown-find --markdown-find-query 词
KAIMING_PREVIEW_CLICK_LINK=1 "$APP/Contents/MacOS/Kaiming" --snapshot-markdown /tmp/link.png --markdown-file /abs/a.md --markdown-render-preview  # 自动点击正文首个链接，验证内链留在预览中
"$APP/Contents/MacOS/Kaiming" --snapshot-settings /tmp/settings.png [--snapshot-settings-tab general|permissions|screenshot|clipboard|markdown|shortcuts|about]
"$APP/Contents/MacOS/Kaiming" --capture-test full      # 真实全屏截图（本次覆盖不复制，不改持久化设置）
"$APP/Contents/MacOS/Kaiming" --capture-test full --capture-test-copy  # 显式验证截图→剪贴板链路
"$APP/Contents/MacOS/Kaiming" --capture-test full --capture-test-decorate  # 显式验证「成品带窗口头部」链路
"$APP/Contents/MacOS/Kaiming" --picker-key-test        # 打开快捷选择并投递 ↓/↓/↑，逐步把窗口截图写到 $KAIMING_PICKER_TEST_DIR
```

`--snapshot-*` 在进程内用真实 `NSWindow + NSHostingView` 渲染，不依赖屏幕录制权限。

验证命令：

```bash
lsappinfo list | grep -A3 Kaiming      # 应显示 type="UIElement"
log show --info --debug --last 5m --predicate 'subsystem == "com.kaiming.app"' --style compact
```

## 2. 权限（统一入口）

- [ ] 权限只在 **设置 → 权限** 展示：屏幕录制 + 辅助功能两项，各含状态、用途、未授权后果。
- [ ] 菜单栏面板不再出现权限横幅；截图失败恢复框只有「打开权限设置 / 重启 Kaiming / 取消」。
- [ ] 截图页 / 长截图页不再有权限状态或「请求权限」按钮，只有跳转「打开权限设置」。
- [ ] 权限页「检测」：屏幕录制走真实 ScreenCaptureKit 探测；检测期间显示进度，完成后状态更新。
- [ ] 权限页「请求权限」触发系统流程；「打开系统设置」跳到 隐私与安全性 → 对应权限页。
- [ ] 权限页「重置授权记录…」清除屏幕录制 TCC 记录并提示重新授权 + 重启（唯一重置入口）。
- [ ] 授权后**重启应用**（权限页「重启应用」），权限页状态变绿，截图可用。
- [ ] 撤销权限（`tccutil reset ScreenCapture com.kaiming.app`）后重启，权限页显示未授权，截图不静默。
- [ ] 已授权但 `CGPreflightScreenCaptureAccess()` 返回 false 时，截图仍按真实 SCK 结果工作（不再假阳性拦截）。
- [ ] `--snapshot-settings ... --snapshot-settings-tab permissions` 渲染出完整权限页，不溢出。

## 3. 截图

### 区域
- [ ] 区域截图快捷键（默认 ⌥⇧S）或面板按钮进入覆盖层；**每块显示器都被覆盖（都变暗、都显示冻结画面）**。
- [ ] 拖拽出现选区 + 尺寸标签；8 个手柄都能调整；选区不能拖出屏幕。
- [ ] Esc 取消且清理所有窗口；Return/双击确认。
- [ ] 确认后图片进入剪贴板（粘贴到备忘录验证）。
- [ ] Retina/4K 屏截图输出为原生像素（本机 3840×2160，不是 1920×1080）。
- [ ] 多显示器：副屏上**第一次按下就能直接框选**（不需要先点一下激活）；裁剪坐标正确。
- [ ] 多显示器：副屏的覆盖层窗口也能用 Return 确认 / Esc 取消（点击后该屏成为 key window）。
- [ ] 多显示器：某块屏无法采集时，其余屏仍可框选，覆盖层内出现「部分显示器无法截取画面」提示。
- [ ] 多显示器排查：stderr 打印 `screens [...] captures [...] failed=[...]` 与每个覆盖层窗口的
      `frame/visible/activeSpace`；副屏缺失时先看这些日志（SCK 是否枚举到、是否配对到 NSScreen）。

### 窗口
- [ ] 窗口截图快捷键（默认 ⌥⇧W）后鼠标悬停高亮单个窗口；点击只截该窗口，不带背景。
- [ ] 窗口截图：副屏上的窗口能悬停高亮、能点选（第一次点击即生效）。
- [ ] 默认（「截图时隐藏 Kaiming 窗口」关闭）本应用窗口也可被选中/截入；开启后本应用自己的窗口/菜单栏不会被选中。
- [ ] 设置 → 截图 → 行为新增「截图时隐藏 Kaiming 窗口」，默认关闭；关闭时在 Markdown 窗口里触发截图，冻结画面保留 Markdown 内容，开启后该内容从截图中消失。

### 全屏
- [ ] 全屏截图快捷键（默认 ⌥⇧F）截取鼠标所在屏幕，无覆盖层，直接完成。

### 标注与后处理
- [ ] 矩形、箭头、文字、颜色、撤销可用，标注位置与最终图一致。
- [ ] 设置「自动复制到剪贴板」关闭后，不再写剪贴板。
- [ ] 设置「自动保存到文件夹」开启后，文件出现在所选目录。
- [ ] 每次截图都在 `~/Library/Application Support/Kaiming/Captures/` 留档；超过 30 张后最旧被清理。
- [ ] 截图声音开关生效；面板显示最近截图缩略图与「刚截取的画面」快捷条。
- [ ] 快捷条：复制到剪贴板、保存副本到截图文件夹、直接设为壁纸、收起；四个动作都有成功/失败提示。
- [ ] 连续快速触发不会叠加多套覆盖层。

### 成品窗口头部（默认开启）

- [ ] 设置 → 截图 → 外观 →「截图成品带窗口头部圆点」默认开启。
- [ ] 区域截图成品顶部有一条 28pt 窗口头部与红黄绿三个圆点；浅色内容配浅色头部、深色内容配深色头部。
- [ ] 剪贴板、自动保存文件、`Captures/` 历史三者是同一张带头部的图片。
- [ ] 带圆角 + 标注时，圆角作用于「头部 + 内容」整体外框，标注位置不偏移。
- [ ] 窗口截图不重复叠加头部（原图已含标题栏）。
- [ ] 关闭开关后，成品宽度不变、高度恢复原生像素（本机 3840×2160），与改动前一致。

## 4. 剪贴板

- [ ] 复制一段文本 → 面板历史出现新记录，类型为文本。
- [ ] 复制图片（截图/预览）→ 历史出现缩略图，图片文件在 `Application Support/Kaiming/Clipboard/`。
- [ ] Finder 复制文件 → 类型为文件 URL，复制按钮能把文件放回剪贴板。
- [ ] 相同内容连续复制不重复入栈。
- [ ] 面板剪贴板页有「收藏 N / 实时 N」两个 tab；复制新内容只让「实时」计数增加。
- [ ] 实时列表里点行尾 ☆ → 该条变成收藏：出现橙色星标，「收藏」计数 +1，切到「收藏」tab 能看到它。
- [ ] 「收藏」tab 按收藏时间倒序，行副标题显示「收藏于 …」；在收藏页点 ★ 取消收藏 → 该条从收藏页消失，回到实时列表。
- [ ] 收藏项在超过上限后仍保留（把上限调到 10 后连续复制 20 条以上），实时列表只淘汰未收藏项。
- [ ] 删除单项同时删除对应图片文件；只清空实时历史后列表里只剩收藏项。
- [ ] 面板「清空实时历史」：点击后在原位出现内联确认卡片（不弹系统弹窗、面板不关闭），文案说明收藏会被保留。
- [ ] 点确认：非收藏项计数归零、图片文件被删除，收藏项与「收藏」tab 内容不变，顶部提示说明保留了几条收藏。
- [ ] 点「取消」或 Esc：历史保留，回到普通「清空实时历史」按钮；切 tab 也会复位确认态。
- [ ] 打开面板 → 点「清空实时历史」→ 不确认直接收起面板 → 再次打开：不得停留在确认卡片。
- [ ] 设置页「清空实时历史（保留收藏）」只清实时历史（普通窗口，允许系统确认弹窗）。
- [ ] 旧版 history.json（`isPinned` 字段）启动后置顶项显示为收藏，且不再被上限淘汰。
- [ ] 关闭「监控剪贴板变化」后不再新增；重新开启后恢复。
- [ ] 在面板点复制不会产生重复历史（自身写入被基线跳过）。
- [ ] 并发压测：快速 pbcopy 循环时无崩溃（串行队列生效）。

## 5. 壁纸

- [ ] 面板列出所有显示器、主屏标记正确。
- [ ] 从剪贴板设置壁纸：桌面立即变化；文件出现在 `Application Support/Kaiming/Wallpapers/`。
- [ ] 壁纸页只有一个「选择壁纸…」入口，不再有「图片/视频」分段控件或两个独立按钮。
- [ ] 同一入口选择图片 → 设为静态壁纸；选择视频（MP4/MOV/M4V）→ 设为动态壁纸；按文件类型自动路由。
- [ ] 选择不支持的文件 → 面板提示「不支持的文件类型」，不写入文件、不改变壁纸。
- [ ] 从图片文件设置：源文件删除后壁纸仍保持（已复制持久化）。
- [ ] 动态壁纸播放中再选择图片：对应屏幕停止动态壁纸并恢复静态壁纸。
- [ ] 壁纸页不展示「最近截图」；来源只有剪贴板（图片）/统一文件入口。
- [ ] 多显示器：只勾选副屏时只改副屏。
- [ ] 退出并重启应用、再重启 Mac 后壁纸仍保持。
- [ ] 无剪贴板图片/坏图片时给出错误提示，不崩溃。

## 6. Markdown

- [ ] 从面板打开 Markdown 窗口，欢迎文档正常渲染（标题、列表、代码块、表格、公式）。
- [ ] 输入 `**粗体**`、`# 标题` 等，光标离开后实时渲染；光标进入元素显示源码。
- [ ] 代码块有语法高亮；`$E=mc^2$` / `$$...$$` 公式渲染。
- [ ] 打开本地 `.md` 成功；保存并重新打开内容一致。
- [ ] 未命名文档保存时弹出保存面板，扩展名 `.md`。
- [ ] 复制按钮把 Markdown 源码放回剪贴板。
- [ ] 字号 +/- 生效并在重启后保持。
- [ ] 未保存修改时新建/打开有确认。
- [ ] 超长文档滚动/输入无明显卡顿。
- [ ] 本地图片（相对/绝对路径）、远程图片渲染；缺失图片保留源码。
- [ ] 内部链接（相对 .md/文本/图片）在应用内打开；外部 http(s) 浏览器打开。
- [ ] 渲染预览中的内部链接留在预览模式跳转：切换到目标 `.md` 的渲染预览（标题栏文件名/大纲同步更新），不弹出外部应用窗口；文本/图片内链进入应用内只读预览。
- [ ] 编辑器/渲染预览内按 ⌘F 出现查找条；Enter/⌘G 下一个、⇧⌘G 上一个、Esc 关闭；`Aa` 区分大小写、`.*` 正则；匹配总数与当前序号实时显示。
- [ ] 编辑器查找替换：「替换」改当前项、「全部替换」一次改完且一次 ⌘Z 可撤销；正则替换支持 `$1` 捕获组；无效正则显示错误提示而不是静默 0 结果。
- [ ] 渲染预览查找：所有匹配高亮、当前项更强并自动滚动到可见位置；替换按钮禁用并提示「渲染预览只读，替换请在编辑模式进行」。
- [ ] 切换编辑 ↔ 渲染预览时，查找条在新目标上重查；关闭查找后高亮清除。
- [ ] 内容导航只显示标题大纲（无链接卡片/HTML 预览/刷新按钮）；点击标题时编辑器滚动到对应位置，渲染预览打开时预览滚动到对应标题并短暂高亮。
- [ ] 表格单元格内的行内代码/加粗/链接正确渲染（不出现反引号源码）。
- [ ] 编辑器与渲染预览内容区不显示滚动条，但滚轮/触控板仍可滚动。
- [ ] 项目树里的 .swift/.ts/.json/.yaml/.sh 等文件预览按类型语法高亮；未知类型仍为纯文本；超过 256KB 不高亮。
- [ ] 开 inspector 时编辑/脏文档保护/保存不回归。
- [ ] 工具栏不再有「从剪贴板载入 / 打开 Markdown 文件 / 打开项目文件夹」按钮；hover 260ms 显示文字提示。
- [ ] 项目文件夹下拉显示最近项目，可切换与移除；重启后最近列表保留。
- [ ] 页宽在默认/较宽/全宽间切换生效；内容区 ⌘+滚轮缩放字号并持久化。
- [ ] 点击内部链接打开新文档后，侧栏展开其父目录、其他目录收起；项目外文件只打开不改树。
- [ ] 右侧内容导航显示标题大纲，点击滚动到对应标题。
- [ ] 含 HTML 的文档出现一键「渲染预览」；HTML 块由 WebView 渲染，`<img>` 相对/绝对/http 图片可见，不显示原始标签。
- [ ] 渲染预览支持 Mermaid 流程图/时序图；错误语法显示错误并保留源码。
- [ ] 远程图片（shields 徽章、Star 趋势 SVG）在预览中渐进加载；本地 HTML 块数量超过 10 时后续块仍按 HTML 渲染（不再被转义）。
- [ ] 渲染预览中导出 PDF：A4、分页不截断正文行、含图表与代码高亮。
- [ ] 渲染预览只读，切回编辑不丢未保存内容。

## 7. 快捷键与设置

- [ ] 默认 ⌥⇧S / W / F / C / M 全部生效（应用在后台时）。
- [ ] 设置 → 快捷键：每行显示当前组合键，点击后变成「按下组合键…」。
- [ ] 按下新的组合键后立即显示在按钮上（例如 ⌃⌥K），**此时还未生效**。
- [ ] 点「保存快捷键」后新组合键生效、旧组合键失效；重启后仍保持。
- [ ] 录制期间原有全局热键被临时注销（按 ⌥⇧S 不会触发截图，只会被录入）。
- [ ] 录制中按 Esc 取消，按钮恢复原来的组合键。
- [ ] 只按字母 / 只按 ⇧ 时拒绝录入，按钮显示「需含 ⌘/⌥/⌃」提示；F1–F20 可单独录入。
- [ ] 两个动作设成同一组合键时，保存按钮禁用并提示冲突，不会写坏配置。
- [ ] 组合键被其他应用占用时，保存后「注册失败」区出现橙色说明。
- [ ] 剪贴板选择窗口、截图面板、Markdown 提示里的快捷键文案跟随自定义值变化。
- [ ] 「恢复全部默认」回到 ⌥⇧ 系列（需再点保存）。
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
- [ ] 剪贴板选择快捷键（默认 ⌥⇧C，自定义后跟随）在后台唤起 520×460 选择窗口，搜索框自动聚焦。
- [ ] ↑/↓ 移动高亮、Return 复制并关闭、Esc 关闭；中文输入法组合期间不抢键。
- [ ] 输入文字能过滤列表（方向键不移动光标而是移动选中项）。
- [ ] `--picker-key-test` 输出的 4 张截图依次高亮第 1/2/3/2 行。
- [ ] 搜索过滤文本/文件名/类型；空历史与无结果有提示；收藏项显示橙色 ☆。
- [ ] 快捷选择窗口有「收藏 / 实时」tab：切换后列表、计数、↑/↓ 选中范围只在当前分区内变化。
- [ ] 「收藏」tab 空态提示「在剪贴板面板里点 ☆ 收藏」，搜索无结果时提示只在收藏里搜索。
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
