# 构建 TwimShelf

## 环境

- Apple Silicon Mac。当前 macOS 目标与 iOS 模拟器 Rust 目标均为 arm64，未提供 Intel 构建配置。
- macOS 应用最低 macOS 15；iOS 应用最低 iOS 18。
- 完整 Xcode 和相应 SDK，选择正确的 Command Line Tools；不是仅安装命令行工具。
- Rust stable / Cargo / rustup、Python 3.9+、Ruby（含 YAML / JSON 标准库）、XcodeGen。
- 首次构建需要下载 Cargo 与 Swift Package 依赖；AI 模型按所用功能另行下载。

安装 Xcode 后打开一次，完成许可和 SDK 安装。通过 Homebrew 安装 XcodeGen：

```sh
brew install xcodegen
# 安装 Rust：按 https://rustup.rs 的官方说明安装，再执行：
source "$HOME/.cargo/env"
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
xcodebuild -version
python3 --version
ruby --version
xcodegen --version
```

若系统没有 Ruby，可使用 `brew install ruby` 并将其加入 PATH。Rust 构建脚本读取 `~/.cargo/env`，请保留 rustup 的标准安装布局。选择 Xcode 可使用 `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`（按实际安装路径调整）。

## 填写自己的构建配置

```sh
cp build-config.example.json build-config.json
```

示例文件中的 Bundle ID、开发团队、App Group、图标名称均为空。`build-config.json` 已被 Git 忽略，不应提交。

| 字段 | 用途 |
| --- | --- |
| `bundle_id_prefix` | 必填，例如 `com.example.twimshelf`；替换为自己的唯一反向域名标识 |
| `development_team` | 签名所用的十位 Team ID；本地无签名检查可留空 |
| `enable_share_extension` | JSON 布尔值，默认 `false`；决定是否生成并嵌入两个平台的分享扩展 |
| `ios_app_group` | 扩展开启时必填，填写已注册的 `group.…` 标识 |
| `macos_app_group` | 扩展开启时必填，填写 `TEAMID.…` 标识 |
| `app_icon_name` | 默认空；添加自己的图标资源集后填写该资源集名称，例如 `AppIcon` |

生成器会从前缀派生 `.ios`、`.mac`、`.mac.debug`、`.ios.share`、`.mac.share`、`.mac.debug.share`、`.uitests` 标识。扩展 ID 位于对应主应用 ID 之下；macOS Debug 与 Release 是不同的应用。应用使用 TwimShelf 命名的资料库、模型缓存目录和独立 Keychain 服务名；macOS 分享回调使用 `twimshelf` / `twimshelf-debug` URL scheme。不会自动迁移其他名称版本的数据。

应用名称是 **TwimShelf**。图标目录只有空的资源目录描述，没有任何图像；系统可能显示默认占位图标。需要正式分发时，请添加符合 Apple 要求的图标并填写 `app_icon_name`。

```sh
python3 scripts/configure.py
open TwimShelf.xcodeproj
```

`project.yml` 是源码模板；请通过生成器构建，不能直接对模板运行 XcodeGen。生成的工程、Info.plist、entitlements、`project.generated.yml` 均被忽略。修改配置或模板后重新执行生成器。内部 target / scheme 保留 `TwitterLibrary-*` 名称以保持源码引用稳定；实际应用名称为 TwimShelf。

## 不构建分享扩展（默认）

保持 `enable_share_extension: false`。生成器会移除两个扩展目标及嵌入依赖，清空共享组配置，生成不带 App Groups 的主应用 entitlements。主应用的文件选择导入仍可使用。

macOS 无签名编译检查：

```sh
xcodebuild -project TwimShelf.xcodeproj -scheme TwitterLibrary-macOS \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

iOS 模拟器编译检查：

```sh
xcodebuild -project TwimShelf.xcodeproj -scheme TwitterLibrary-iOS \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

无签名编译成功不等于可分发。运行、真机安装及发布需要适合目标平台的签名。在 Xcode 中选择设备与团队后运行；如需持久修改签名，请修改配置文件并重新生成，避免只改生成的工程。

## 构建分享扩展

分享扩展通过 **App Groups** 把文件交给主应用。首次构建需要配置自己的开发者团队和共享组；如果账号中已经配置好，只需填写现有标识，无需重复注册。

1. 在 `build-config.json` 填写 `development_team`、`ios_app_group` 和 `macos_app_group`，将 **`enable_share_extension` 改为 `true`**。
2. 运行 `python3 scripts/configure.py`，再打开生成的 Xcode 工程。扩展目标、嵌入关系和共享组权限会自动配置。
3. 在 Xcode 的 Signing & Capabilities 中确认主应用和扩展使用自己的团队，且同一平台的两者加入同一 App Group，然后构建运行。若尚未注册这些标识，可在这里配置并由 Xcode 管理签名。

本实现需要支持 App Groups 的开发者团队，通常使用 Apple Developer Program 会员账号；具体能力见 [Apple 说明](https://developer.apple.com/help/account/capabilities/capabilities-overview)和 [App Groups 配置](https://developer.apple.com/documentation/xcode/configuring-app-groups)。无需分享扩展时，保持 `false` 即可。开关目前同时控制两个平台，开启时需填写两个平台的共享组标识。

## 测试

Rust 离线测试：

```sh
cd core
cargo test --workspace --locked
cd ..
```

构建配置测试：`python3 -m unittest discover -s scripts -p 'test_*.py' -v`。

现有 Swift / 前端契约检查入口：`scripts/checks/run.sh`。iOS UI 测试使用 `TwitterLibrary-iOS` scheme；请先在 Xcode 选择已安装的模拟器。

仓库没有测试数据库、真实媒体、录制手势 JSON、保存的网络响应 JSON 或 property-test 回归数据文件。测试中的合成输入和临时数据生成逻辑属于测试代码，保留在源码中。

- `core/protected/src/tests.rs` 中依赖保存响应的测试标记为 ignored，并改为运行时读取 `core/protected/tests/fixtures/`。自行补充对应数据后再选择性运行这些测试。不要直接运行全部 `--ignored`：其中也有联网与凭据相关测试。
- 大型媒体、真实压缩包和联网测试的输入要求见对应测试源码；不分发这些输入。

## 依赖与分发

`core/Cargo.lock` 固定 Rust 依赖；`dependencies/Package.resolved` 保存 Swift 依赖解析结果，生成器会复制到新工程。模型与第三方库各自的许可证不被项目 MIT 许可证覆盖；发布二进制时应整理实际分发依赖的许可证声明。
