# 构建、签名与公证

## 1. 本地开发

```bash
./Scripts/build.sh          # Debug
./Scripts/build.sh Release  # Release
./Scripts/run.sh            # 构建并启动 Debug
```

工程产物：

- `build/dd/Build/Products/Debug/Kaiming.app`
- 内置 `Kaiming.app/Contents/Frameworks/MarkdownEngine.framework`
- 资源：`highlight.min.js`、`mathFonts.bundle`、`Assets.car`

### 关于 App Sandbox

默认 **关闭 App Sandbox**（`ENABLE_APP_SANDBOX = NO`）：

- Developer ID 分发并不要求沙盒；
- 壁纸设置需要系统壁纸服务读取持久文件，沙盒容器路径在部分系统版本上会导致
  `setDesktopImageURL` 失败；
- 截图 TCC 权限与沙盒无关。

`Config/Kaiming.entitlements` 是一份沙盒模板（app-sandbox + user-selected + bookmark），
**当前未接入 build settings**（默认 `ENABLE_APP_SANDBOX = NO`）。上架 Mac App Store 时需要手动：

1. 在 target 设置里为 Release 配置 `CODE_SIGN_ENTITLEMENTS = Config/Kaiming.entitlements`；
2. 把壁纸持久目录改为用户通过 `NSOpenPanel` 选择的 `~/Pictures` 子目录，并持久化
   security-scoped bookmark；
3. 重新验证屏幕录制、壁纸、自动保存目录三条链路（沙盒下容器文件可能不可被壁纸服务读取）。

未完成以上步骤前，`Kaiming.entitlements` 不会自动生效。

## 2. 签名（Developer ID）

前置条件：

- Apple Developer Program 会员；
- 钥匙串里有 `Developer ID Application: <Name> (<TEAMID>)` 证书；
- Xcode 已登录账号。

```bash
DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/archive.sh --sign
```

脚本会：

1. `xcodebuild archive`（Release、时间戳签名）；
   工程 Release 配置默认关闭 Hardened Runtime：ad-hoc 签名下 app 与内嵌
   `MarkdownEngine.framework` 的 Team ID 不同，dyld 库验证会拒绝加载。
   `--sign` 分支会重新开启 Hardened Runtime，并由同一 Developer ID 证书重签
   app 与 framework，满足公证要求。
2. `-exportArchive` 生成 `build/export/Kaiming.app`；
3. `codesign --verify --deep --strict`；
4. 生成 DMG：`build/Kaiming-1.1.1.dmg`。

检查签名：

```bash
codesign -dv --verbose=4 build/export/Kaiming.app
codesign --verify --deep --strict --verbose=2 build/export/Kaiming.app
```

## 3. 公证（Notarization）

```bash
export APPLE_ID=you@example.com
export APPLE_TEAM_ID=ABCDE12345
export APP_NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx   # app-specific password
./Scripts/notarize.sh build/export/Kaiming.app
```

或者使用钥匙串配置：

```bash
xcrun notarytool store-credentials KaimingNotary \
  --apple-id you@example.com --team-id ABCDE12345 --password xxxx-xxxx-xxxx-xxxx
NOTARY_PROFILE=KaimingNotary ./Scripts/notarize.sh
```

脚本执行 `notarytool submit --wait` → `stapler staple` → `spctl --assess`。
首次公证通常 1–15 分钟。

## 4. 分发前检查

- [ ] `./Scripts/build.sh` 无 error；
- [ ] `codesign --verify --deep --strict` 通过；
- [ ] `spctl --assess --type execute` 返回 `accepted`；
- [ ] 在一台**没有开发环境**的 Mac 上首次打开无安全警告；
- [ ] 屏幕录制权限引导可用（授权后重启生效）；
- [ ] 壁纸重启后保持；
- [ ] Markdown 窗口可打开、编辑、保存；
- [ ] app 只常驻菜单栏，无 Dock 图标。

## 5. 版本号

- `MARKETING_VERSION`：`Config/Info.plist` 里通过 `$(MARKETING_VERSION)` 注入，当前 1.1.1；
- `CURRENT_PROJECT_VERSION`（build）：当前 3；
- 发版时同步修改 `Kaiming.xcodeproj` target 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。

## 6. 已知环境限制

- 本机若在受限 Sandbox 中构建，Xcode 的 SwiftPM manifest 缓存无法写入 `~/Library/Caches`；
  本项目已内嵌 Markdown 引擎，不依赖 SwiftPM，因此构建不受影响。
- `Scripts/archive.sh` 的 Developer ID 分支需要真实证书；ad-hoc 分支可本地运行验证功能，
  但不能通过 Gatekeeper。
- 在受限 Sandbox/CI 中 `hdiutil` 可能无法创建 DMG（无法挂载设备）；脚本会保留
  `build/export/Kaiming.app` 并给出警告，换到正常用户会话即可生成 DMG。
