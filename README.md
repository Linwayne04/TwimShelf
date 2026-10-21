# TwimShelf

将x帖子下载到本地并管理它们

TwimShelf 是面向 **macOS 和 iOS** 的原生应用。使用原生UI技术构建，后端基于rust，支持在多设备之间去中心化本地同步，不依赖iCloud

## 可以做什么

- **收集媒体**：遇到喜欢的内容可以下载保存，不必担心作者删除或清空账号。支持批量下载你的收藏夹，需使用第三方扩展导出json文件
- **浏览与搜索**：主页随机出现已保存媒体内容，每次打开都可以查看不同口味。支持多种条件筛选，照片库缩放效果向Apple相册看齐
- **AI 标记**：AI可以根据媒体和帖子内容打标签，支持本地AI和外部AI服务，可以接入grok
- **设备间同步**：在局域网中配对设备，去中心化同步，不需要付费开发者ID才能使用的iCloud同步
- **备份与维护**：可以按照标签等导出特定范围的媒体，导出按钮就在搜索按钮旁边
- **系统分享扩展（可选）**：以前存储在相册里的图片也可以快速导入


## 构建

请阅读 **[构建指南](BUILDING.md)**。

公开源码默认使用应用名称 **TwimShelf**，不附带应用图标，Bundle ID、开发团队和 App Group 配置为空。如需构建，必须填写自己的 Bundle ID；需要签名或分享扩展时，再填写自己的开发者配置。

```sh
cp build-config.example.json build-config.json
# 编辑 build-config.json，至少填写 bundle_id_prefix
python3 scripts/configure.py
open TwimShelf.xcodeproj
```

分享扩展由 `build-config.json` 中的一个布尔值控制：

```json
"enable_share_extension": false
```

修改为 `true` 并完成 App Group 与签名配置后，重新生成工程即可构建扩展。详细要求见构建指南。

## 源码结构

| 目录 | 内容 |
| --- | --- |
| `app/Shared` | 两个平台共享的界面、媒体浏览、AI 与核心桥接 |
| `app/iOS`、`app/macOS` | 平台入口及适配 |
| `app/ShareExtension` | 可选的系统分享扩展 |
| `core/src` | 数据库、导入、同步、搜索与资料库管理 |
| `core/protected`、`core/protected-api` | 需要登录的帖子访问模块及接口 |
| `core/tests`、`app/iOSUITests` | 测试代码 |
| `scripts` | 工程生成、Rust 构建与检查脚本 |

仓库不包含个人资料库、媒体、凭据和录制的测试数据。测试代码保留；依赖未分发数据的测试需要自行提供数据，具体见构建指南。

## 贡献

欢迎通过 Issue 描述问题，或通过 Pull Request 提交改进。涉及数据库或同步协议的修改，请补充能够验证数据一致性的测试。请勿提交个人签名配置、真实账号凭据、媒体或测试资料库

## 许可证

项目代码采用 [MIT 许可证](LICENSE)：允许使用、修改、分发和商业使用，须保留版权与许可证声明。第三方依赖及下载的模型仍适用各自的许可证。

TwimShelf 是独立项目，与 Twitter / X 没有隶属关系。导入内容的权利仍属于各自的权利人，不可用于分享
