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
- [ ] 菜单栏图标点击弹出 400×580 面板，三个 Tab（截图/剪贴板/系统）可切换。
- [ ] 点面板右上 Markdown 图标打开独立窗口；关闭后可再次打开。
- [ ] 设置窗口可打开（面板底部齿轮 / ⌘,）。
- [ ] 多显示器：鼠标停在副屏时 ⌥⇧M / ⌥⇧C，窗口出现在**副屏中央**（不是主屏）。
- [ ] 多 Space：把 Markdown 窗口留在别的桌面，回到桌面 1 按 ⌥⇧M，窗口跟到当前桌面出现，桌面不滑动。
- [ ] Markdown 窗口手动摆好位置后再打开，位置保持不变（不每次强制居中）；窗口比当前屏幕大时先收缩再居中。
- [ ] 调试日志：`log stream --predicate 'process == "Kaiming"' | grep placed` 能看到 `placed <scene> window on screen ...`。

调试构建提供以下验证钩子（Release 不包含；见 `#if DEBUG`）：

```bash
APP=build/dd/Build/Products/Debug/Kaiming.app
"$APP/Contents/MacOS/Kaiming" --open-markdown          # 打开 Markdown 窗口
"$APP/Contents/MacOS/Kaiming" --open-settings          # 打开设置窗口
"$APP/Contents/MacOS/Kaiming" --open-clipboard         # 打开剪贴板快捷选择窗口
"$APP/Contents/MacOS/Kaiming" --open-folder /abs/path  # 模拟 CLI 打开目录树
"$APP/Contents/MacOS/Kaiming" --snapshot-panel /tmp/panel.png [--snapshot-tab clipboard|system] [--snapshot-fake-capture] [--snapshot-clipboard-scope live|favorites] [--snapshot-system-section clean|features|uninstall]
# 系统页首次会扫描 ~/Library/Caches，如需截图里显示扫描结果：KAIMING_SNAPSHOT_DELAY=10
"$APP/Contents/MacOS/Kaiming" --logic-test-system   # 采样 / 缓存扫描 / 内存释放自检（只读 + 一次释放）
"$APP/Contents/MacOS/Kaiming" --logic-test-uninstall /tmp/uninstall-test.txt  # 卸载器夹具自检（创建并清理临时文件）
KAIMING_UNINSTALL_SELECT=bestzip KAIMING_UNINSTALL_CONFIRM=1 KAIMING_SNAPSHOT_DELAY=9 \
"$APP/Contents/MacOS/Kaiming" --snapshot-panel /tmp/uninstall-detail.png --snapshot-tab system --snapshot-system-section uninstall
# 以上 auto-select / confirm 仅 DEBUG 生效；uninstall 自检需要写入 ~/Applications 与 ~/Library
# 的测试夹具，在 DSH 沙盒里运行会失败，请用正常 App 进程或完全磁盘访问权限运行。
"$APP/Contents/MacOS/Kaiming" --snapshot-menubar-label /tmp/menubar.png  # 菜单栏标签（图标 + 数值）
# --snapshot-fake-capture 用合成图片填充“刚截取的画面”快捷条，便于无 TCC 权限时验收
# --snapshot-clipboard-scope 让剪贴板页直接渲染「收藏」或「实时」分区
"$APP/Contents/MacOS/Kaiming" --snapshot-clipboard-picker /tmp/picker.png [--snapshot-clipboard-scope live|favorites]
# 截图想用固定样例、不动真实历史时：KAIMING_SUPPORT_DIR=/tmp/kaiming-support 指向临时数据目录（仅 DEBUG 生效）
"$APP/Contents/MacOS/Kaiming" --snapshot-markdown /tmp/markdown.png
"$APP/Contents/MacOS/Kaiming" --snapshot-markdown /tmp/find.png --markdown-find [--markdown-find-query 词] [--markdown-find-regex] [--markdown-find-replacement 词] [--markdown-find-replace-all]
"$APP/Contents/MacOS/Kaiming" --snapshot-markdown /tmp/preview-find.png --markdown-render-preview --markdown-find --markdown-find-query 词
KAIMING_PREVIEW_CLICK_LINK=1 "$APP/Contents/MacOS/Kaiming" --snapshot-markdown /tmp/link.png --markdown-file /abs/a.md --markdown-render-preview  # 自动点击正文首个链接，验证内链留在预览中
"$APP/Contents/MacOS/Kaiming" --snapshot-settings /tmp/settings.png [--snapshot-settings-tab general|permissions|screenshot|clipboard|markdown|shortcuts|about]
"$APP/Contents/MacOS/Kaiming" --snapshot-annotation-toolbar /tmp/toolbar.png  # 790pt 工具栏完整渲染（含删除按钮）
"$APP/Contents/MacOS/Kaiming" --logic-test-annotations  # 命中/拖动夹取/手柄缩放/文字与画笔命中/撤销栈
"$APP/Contents/MacOS/Kaiming" --logic-test-overlay-interactions  # 覆盖层 mouseDown/Dragged/Up → 选中拖动/手柄缩放/撤销
"$APP/Contents/MacOS/Kaiming" --logic-test-overlay-view  # 真实 CaptureOverlayView 事件路径：画完自动选中并直接拖动
"$APP/Contents/MacOS/Kaiming" --render-test-rounded /tmp/rounded.png  # 成品 PNG 四角 alpha=0 + 编码往返校验
"$APP/Contents/MacOS/Kaiming" --render-test-overlay-corners /tmp/overlay.png  # 覆盖层预览四角透明（离屏绘制）
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
- [ ] 已有标注编辑：画完矩形/箭头/文字后无需切换工具，标注自动出现虚线选中框；
  按住拖动可整体移动，拖到选区边缘不会越界；点击空白处收起选中并继续绘制下一条。
- [ ] 切换「调整选区 / 编辑标注」后单击任意已有标注出现虚线选中框；
  按住拖动可整体移动，拖到选区边缘不会越界。
- [ ] 矩形/马赛克选中后 8 个手柄可缩放，箭头选中后拖动起点/终点手柄可改方向与长度；
  缩放后的标注位置与最终 PNG 一致。
- [ ] 双击文字标注进入编辑（预填原文），Return 提交、Esc 取消；清空内容提交后该标注消失。
- [ ] Delete / 前向删除删除选中标注；Esc 先取消选中、再取消截图；⌘Z 可撤销新增、
  拖动、缩放、文字修改与删除；工具栏垃圾桶按钮仅在选中标注时可用。
- [ ] 画笔（手写）：选择画笔工具后在选区内按住拖拽，实时出现平滑笔迹（无明显折线棱角）；松开后笔迹保留、可撤销；确认后 PNG 同位置有同样的手写笔迹（区域 / 窗口 / 长截图三种来源一致），笔迹不越出选区。
- [ ] 马赛克：选择「马赛克」工具后拖出矩形区域，预览立即呈块状像素化；确认后 PNG 同一区域同样像素化（区域 / 窗口 / 长截图三种来源一致），可选撤销。
- [ ] 设置「自动复制到剪贴板」关闭后，不再写剪贴板。
- [ ] 设置「自动保存到文件夹」开启后，文件出现在所选目录。
- [ ] 每次截图都在 `~/Library/Application Support/Kaiming/Captures/` 留档；超过 30 张后最旧被清理。
- [ ] 截图声音开关生效；面板显示最近截图缩略图与「刚截取的画面」快捷条。
- [ ] 快捷条：复制到剪贴板、保存副本到截图文件夹、收起；三个动作都有成功/失败提示。
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

## 5. Markdown

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

## 6. 快捷键与设置

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
- [ ] 设置窗口统一为「图标卡片」布局，七个分类页可滚动；开关、Picker、Stepper、录制与保存均正常。
- [ ] 「登录时自动启动」在签名构建上可注册/注销；失败时显示系统错误。
- [ ] 「恢复默认设置」清空自定义值并重新注册快捷键。

## 7. 分发

- [ ] `./Scripts/archive.sh` 生成 `.xcarchive`、`build/export/Kaiming.app`、DMG。
- [ ] Developer ID 构建：`codesign --verify --deep --strict` 通过。
- [ ] 公证：`./Scripts/notarize.sh` 成功，`spctl --assess` 为 accepted。
- [ ] 干净机器首次打开无「无法验证开发者」提示。

## 8. 交付标准对照

| 规格 | 验收点 |
|---|---|
| 1 菜单栏常驻、无 Dock | 1 启动 |
| 2 三种截图 + 标注 + 自动进剪贴板 | 3 全部 |
| 3 剪贴板类型/历史/复制/清除 | 4 全部 |
| 4 Markdown 独立窗口/载入/编辑/预览/保存 | 5 全部 |
| 5 同一工程共享权限与设置 | 工程结构 + 1/6 |
| 6 首次权限引导 | 2 全部 |
| 7 可签名公证 | 7 全部 |

## 9. v1.1 新功能验收

### 剪贴板快捷选择
- [ ] 剪贴板选择快捷键（默认 ⌥⇧C，自定义后跟随）在后台唤起 520×460 选择窗口，搜索框自动聚焦。
- [ ] ↑/↓ 移动高亮、Return 复制并关闭、Esc 关闭；中文输入法组合期间不抢键。
- [ ] 输入文字能过滤列表（方向键不移动光标而是移动选中项）。
- [ ] `--picker-key-test` 输出的 4 张截图依次高亮第 1/2/3/2 行。
- [ ] 搜索过滤文本/文件名/类型；空历史与无结果有提示；收藏项显示橙色实心 ☆。
- [ ] 快捷选择窗口有「收藏 / 实时」tab：切换后列表、计数、↑/↓ 选中范围只在当前分区内变化。
- [ ] 每行右侧 ☆ 可收藏/取消收藏且不触发复制；选中行按 ⌘D 同样切换收藏。
- [ ] 收藏「当前剪贴板」临时条目后会写入历史，并立即出现在「收藏」分区。
- [ ] 「收藏」tab 空态提示「在任意记录右侧点 ☆ 收藏」，搜索无结果时提示只在收藏里搜索。
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

### 截图圆角 / 长截图
- [ ] 圆角 0–48pt 可调，预览与导出 PNG 一致，圆角外透明。
- [ ] 圆角预览：四个圆角区域完全透明（能直接看到桌面），不是被暗色遮罩/冻结底图填满；
      拖动圆角滑杆时四角实时变化。
- [ ] 自动化：`--render-test-overlay-corners` 与 `--render-test-rounded` 均输出 PASS；
      后者 PNG 四角 alpha=0、中心 alpha=255，且 PNG 编码/解码往返后仍透明。
- [ ] 区域长截图：点击后**直接进入手动滚动**，选区边框持续可见；用户滚动实时页面，HUD 显示采集进度。
- [ ] HUD「自动滚动」：未授权辅助功能时提示并保持手动；授权后自动滚动并与已拼接内容连续。
- [ ] 完成/取消/自动无变化/手动长时间无变化/20000px 上限均正确停止并进入预览确认。
- [ ] 拼接结果无重复内容/无断裂；无变化、超过 20000px、Esc 取消均正确提示。
- [ ] 长截图结果进入预览确认，之后正常写剪贴板/历史/自动保存。

## 10. 系统资源

### 采样
- [ ] 打开「系统」tab，2 秒内出现内存百分比、CPU 负载、磁盘、网络速率；网络曲线在采样 2 帧后出现。
- [ ] 面板收起后系统采样停止（用活动监视器观察 Kaiming 的 CPU / 能耗回落）；再次打开后数值继续刷新。
- [ ] 切到截图 / 剪贴板 tab 后同样停止，返回系统 tab 恢复。
- [ ] 内存百分比与活动监视器的「已用内存」接近（±5%），交换区用量显示在卡片右下。
- [ ] 应用内存前 5 名按字节降序；第 6 行起聚合为「其他 N 个应用」，合计等于其余应用 footprint 之和。
- [ ] 无风扇机型（MacBook Air）风扇显示「—」，不影响温度 / 负载；无温度传感器的机型显示「—」。
- [ ] 亮色 / 深色模式切换后面板颜色、卡片、曲线均正常（`--snapshot` 可验证）。

### 清理释放
- [ ] 首次进入自动扫描；扫描期间显示「扫描中…」，完成后显示可清理总量与三类大小。
- [ ] 勾选 / 取消类别后，确认卡片中的总量与「清理」按钮可用状态同步变化。
- [ ] 点「清理」出现**面板内**确认卡片（不弹系统弹窗、面板不收起）；取消后回到类别勾选。
- [ ] 确认清理后显示进度，完成后顶部 notice 显示实际清理量，缓存大小刷新。
- [ ] 最近 1 小时内修改的缓存文件保留（`find ~/Library/Caches -newermt '-1 hour'` 抽查）。
- [ ] 关闭面板时确认卡片复位；再次打开不会停在确认态。
- [ ] 「释放」期间按钮显示「释放中」，完成后 notice 显示采样差值；内存百分比刷新。

### 传感器 / 权限
- [ ] CPU 温度来源标注为「CPU 集群 / PMU 晶粒 / SOC 晶粒」，数值在 20–110°C 合理区间。
- [ ] 风扇转速与第三方工具（如 Stats / iStat Menus）读数接近（±5%）。
- [ ] 读取失败只降级为「—」，不崩溃、不弹权限框（本模块不需要 TCC 权限）。
- [ ] `--logic-test-system` 输出 memory / cpu / disk / sensors / network / apps / cache-scan / release 各一行，且进程正常退出。

### 状态栏指标（v1.2）
- [ ] 首次启动 / 未写入过设置时，系统功能页「状态栏」7 个标签全部选中，菜单栏显示图标 + 7 项指标。
- [ ] 关闭某个标签后，菜单栏对应指标立即消失；重新打开立即出现，无需重启。
- [ ] 全部关闭后菜单栏只剩开明图标；重新打开任一指标后恢复，选择在重启应用后保持。
- [ ] 菜单栏显示温度计 / CPU / 风扇 / 内存 / 磁盘 / 上下行箭头图标与数值，与系统功能页一致。
- [ ] 面板打开时约 2 秒更新；收起面板但状态栏仍有指标时约 3 秒更新；全部关闭且面板收起后不再采样。
- [ ] 温度 / 风扇不可用的机型，菜单栏对应位置显示「—」，其余指标正常。
- [ ] `--snapshot-menubar-label` 渲染出完整指标条，暗色 / 亮色下文字均清晰。
- [ ] 菜单栏空间紧张时（小屏 + 多项指标）可通过关闭部分指标把宽度降下来。

## 11. 应用卸载（v1.2）

### 列表与扫描
- [ ] 系统页第三个 tab「应用卸载」；首次进入显示 `/Applications` + `~/Applications` 第三方应用。
- [ ] Apple 系统应用（`com.apple.*`）与开明自身不出现；符号链接应用跳过。
- [ ] 搜索框按应用名 / bundle id 过滤；运行中的应用显示「运行中」。
- [ ] 选择应用后自动扫描；应用本体、共享容器、沙盒容器、支持文件、缓存、偏好、日志、
      窗口状态、网络数据、脚本、插件/扩展、启动项、用户目录同名项按类别显示，默认全选。
- [ ] 用户目录同名项显示橙色「请确认不是个人文件」；取消勾选后不删除。
- [ ] 取消勾选非应用本体条目后，总量与按钮文案同步变化；「全选 / 全不选」不取消应用本体。
- [ ] 应用本体行带锁/不可取消；卸载按钮旁显示将删除的总大小。

### 确认与删除
- [ ] 点「卸载并删除」出现面板内红色确认卡片（不弹系统弹窗、面板不收起）；取消后回到详情。
- [ ] 确认后运行中的应用先退出；未运行的应用直接进入删除；期间显示「正在退出并删除…」。
- [ ] 应用拒绝退出时中止，详情显示「未能退出该应用」，不删除任何文件。
- [ ] 应用本体删除失败时立即中止，不继续删除缓存/偏好；详情保留并显示失败路径。
- [ ] 应用本体删除成功、部分关联文件失败时，详情保留失败摘要；应用已从列表消失。
- [ ] 全部成功后返回应用列表、该应用消失，顶部 notice 显示释放量。
- [ ] 未授予完全磁盘访问权限时，Cookies / 容器等失败，不影响应用本体删除，失败项可见/可查日志。

### 夹具自检
- [ ] `--logic-test-uninstall` 输出 `PASS=true`，`items` / `removed` ≥ 15，`decoysKept=true`，
      `guard=true`；结束后 `~/Applications/KaimingUninstallTest.app`、`~/Documents/KaimingUninstallTest`
      与测试缓存全部清理。
- [ ] 自检创建的 `com.kaiming.uninstall-test2` / `KaimingUninstallTest2` 诱饵未被删除
      （bundle id 前缀匹配不能误伤纯数字后缀）。
