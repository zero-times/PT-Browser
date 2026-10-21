# 验证记录

## 1.0.2 (3) 网页命名 — 2026-10-21

`build/Tests-1.0.2.xcresult`：**25 项通过，0 失败**（24 项单元/集成测试 + 1 项 UI 测试）。新增验证覆盖真实 WKWebView 中的图片 alt、图注、video/source 标题、资源链接文字、Open Graph 网页标题、动态名称更新与后续网络记录保留命名；loopback HTTP 下载确认 Content-Disposition 素材名不会覆盖网页标题，MIME 决定扩展名，同名自动编号，命名后视频仍可播放和加密解密，以及旧下载队列兼容读取。

下载任务创建时保存页面名称，重试/后台恢复保留该名称。无页面元数据的手动直接链接仍使用响应/资源名称；已有下载不追溯重命名。名称包含点号时保留有意义的文字，HLS 使用网页名加 `.movpkg`，长中文标题按 UTF-8 文件名字节限制截取。

交付 `build/Export/PTBrowser-1.0.2-INGOO.ipa`，包名与团队不变。


## 1.0.1 (2) 路径修复回归 — 2026-10-21

`build/Tests-1.0.1.xcresult`：**20 项通过，0 失败**（19 项单元/集成测试 + 1 项 UI 测试）。

修复 Files 返回的目录别名与枚举结果不一致时，按绝对路径字符串长度截取导致的普通媒体路径错误。现在用解析后的路径组件计算相对位置，并采用文件协调器返回的真实读写 URL。导入、加密与校验同时协调源文件读取，目录授权在操作期间保持有效。启动/重新扫描会修复可匹配的旧普通索引，保留媒体 ID、收藏与哈希；原媒体文件不移动、不重下。

新增回归涵盖真实 MP4 从 HTTP 下载到别名文件夹后的扫描、AVFoundation 打开、加密及解密，独立实例恢复，旧错误索引修复，空别名文件夹初始化，以及嵌套媒体包相对路径。旧版本已复现失败，新版本上述流程全部通过。未操作用户手机上的实际视频，真实 FileProvider 的云端中断行为仍需真机验证。

INGOO Archive、Export、代码签名严格校验及 IPA 压缩包检查均通过。交付 `build/Export/PTBrowser-1.0.1-INGOO.ipa`，包名不变，可覆盖安装保留原 App 数据。

以下为首版验证记录。


2026-10-21，Asia/Shanghai。Xcode 27.0 (27A266a)，iOS 27.0 模拟器，iPhone 18 Pro。

## 自动验证

`build/Tests-Delivery.xcresult`：**16 项通过，0 失败**。

- BrowserTests 3 项：地址/搜索解析，拒绝 file/blob 嗅探地址与去重，DOM/lazy/srcset/poster/HLS 链接及动态 video 的真实 WKWebView 嗅探。
- DownloadTests 3 项：真实 loopback HTTP 图片下载并导入 Files、SHA-256 生成，HTML 登录页拒绝，伪图片与预期哈希不符拒绝。
- LibraryRepositoryTests 6 项：全新仓库实例读取普通媒体并凭原密码恢复加密媒体，原件删除时序与缓存清除，文件夹/重命名/收藏/冲突文件名，校验与删除，媒体包逐文件加密还原，路径遍历/符号链接越界拒绝，真实 MP4 加密后重新打开并通过 AVFoundation 可播放性/时长/哈希检查。
- VaultCryptoTests 3 项：空文件和跨块文件往返、每次不同 nonce，UTF-8 密码与可迁移密钥派生，错误密码/库 ID/文件 ID/密钥、密文翻转、最终块标记篡改、截断和尾随数据拒绝并清除失败输出。
- AppUITests 1 项：启动四个主要页面、创建加密库、锁定、浏览器地址栏与 Files 文件夹入口。

模拟器界面截图：`build/Screenshots/library.png`。该截图为界面检查时的空媒体库，不是预置样例数据。

## 签名与安装包

`./scripts/build_ipa.sh` 已成功完成 Archive、Export 和严格代码签名验证。

- IPA：`build/Export/PTBrowser.ipa`
- Bundle ID：`com.hoai.ptbrowser`
- 版本：`1.0.0 (1)`，最低 iOS 17.0，arm64，iPhone / iPad
- Team：`INGOO TECHNOLOGY LTDA`，`96P5S5A5C3`
- 签名：INGOO 团队所属 Apple Development 证书
- 描述文件：`iOS Team Provisioning Profile: *`（开发签名，只适用于描述文件登记设备）
- Archive：`build/PTBrowser-Signed.xcarchive`

## 实际验证边界

尚未安装到用户真机，未对真实目标网站进行登录/防盗链/HLS 站点回归，未对真实 iCloud / 第三方 FileProvider 的同步中断、冲突文件和重授权行为进行真机测试。普通媒体后台音频与画中画已配置，加密媒体在失活时停止播放并锁定；系统实际调度和 PiP 行为仍需真机确认。

换包名恢复通过完全独立的文件库实例验证，不依赖原实例内存、Bundle ID 或钥匙串；尚未同时安装第二个 Bundle ID 的 App 做真机交叉验证。加密实现通过功能与篡改测试，尚未经过独立安全审计。
