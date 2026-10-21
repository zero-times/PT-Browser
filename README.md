# PT Browser

原生 iOS 私密媒体浏览器，SwiftUI + WebKit + AVKit，iOS 17+，iPhone / iPad。包名 `com.hoai.ptbrowser`，INGOO 团队 `96P5S5A5C3`。不依赖第三方 SDK、服务端、账号或云端密钥。

## 运行

直接打开 `PTBrowser.xcodeproj`，选择 `PTBrowser` scheme。在 Signing & Capabilities 中使用 INGOO 团队，选择设备后运行。

```sh
# 工程配置的唯一来源，修改配置后重新生成（需 brew install xcodegen）
xcodegen generate

# 使用本机模拟器；也可替换成自己的 destination
xcodebuild -project PTBrowser.xcodeproj -scheme PTBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

## 已实现的工作流

- **媒体库**：Files 多选导入、自动扫描已有媒体及子目录、网格/列表、名称搜索、类型/文件夹/收藏筛选、时间/名称排序、收藏、重命名、批量移动/删除/加密/解密、系统分享导出、SHA-256 校验。
- **Files 文件夹**：默认在 App 的 Documents/Media，支持用系统文件夹选择器连接 iCloud Drive、在我的 iPhone 或第三方文件提供商。使用安全作用域书签恢复授权，NSFileCoordinator 协调文件读写。资源直接存入文件夹，不以数据库 BLOB 存储。
- **加密隐藏**：AES-256-GCM 分块加密（1 MiB），PBKDF2-HMAC-SHA256（310,000 次、32 字节随机盐），加密索引包含私密名称、类型和文件清单。后台/失活自动锁定，遮盖 App 切换快照，删除临时解密副本。原密码不保存到钥匙串。
- **图片**：左右/上下分页切换、捏合缩放、双击缩放、长图按屏宽纵向阅读、2/4/8 秒幻灯片、有限帧数 GIF 动画。对极大图片和动画限制解码像素以控制内存，原文件保持原始分辨率。
- **影音**：原生 AVPlayerViewController（进度拖动、系统支持的音轨/字幕/全屏/AirPlay/PiP 控件）、0.5–2 倍速、静音、普通媒体断点续播、自动下一项、上下滑动短视频模式。加密内容不保存播放进度，失活会停止播放并锁定。
- **浏览器**：独立多标签（最多 30）、默认无痕、普通标签登录 Cookie、地址/搜索、前后导航和侧滑、刷新/停止、书签、历史、页面查找、网页缩放、桌面 UA、网页分享、JS alert/confirm/prompt、清除网站数据。
- **嗅探**：在所有 frame 的 document-start 注入脚本，收集 img/video/audio/source、lazy src、srcset、poster、Open Graph、内联背景图、动态 DOM、开放 Shadow DOM、Fetch/XHR MIME 与 Performance 资源记录；地址去重和类型/小图过滤、选择批量下载。
- **网页命名**：下载图片/视频优先使用页面上的媒体标题、图片 alt、图注或所属文章标题，没有单独名称时使用网页标题（Open Graph / 标签标题）。名字在嗅探列表、下载队列和 Files 媒体库保持一致；响应头里的素材文件名不会覆盖网页名称。扩展名使用实际响应类型，同名自动编号，中文长标题按 UTF-8 字节限制处理。仅影响新下载，旧文件保持原名。
- **下载**：URLSession 后台下载、进度、取消、暂停（取决于服务器 Range/resume 支持）、重试、重启恢复；携带所选页面与资源域匹配的 Cookie、来源和 UA。HTTP 状态/长度/MIME/可解码性检查、流式 SHA-256 与可选预期哈希校验，完成后保存到创建任务时指定的文件库。
- **HLS**：AVAssetDownloadURLSession 系统非 DRM 点播离线下载，保存为 `.movpkg` 包；支持包中每个文件分别加密、解密恢复离线包。

## 换包名 / 重装后恢复

1. **事先把文件库选在 iCloud Drive 或独立文件提供商中。** App 自己的「在我的 iPhone / PT Browser」目录仍属于沙盒，卸载 App 会删除它；Files 可见不等于卸载后保留。
2. 备份或迁移时复制**整个文件夹**，务必包含 `.ptbrowser` 隐藏目录。可在 Mac Finder 使用 `Command + Shift + .` 显示隐藏文件后检查。普通媒体文件和隐藏加密目录必须一起保留。
3. 新包名安装后，在设置中点「选择 / 恢复已有文件夹」，选择原来的根目录。
4. 普通媒体直接扫描显示；在媒体库「隐藏」中输入原密码解锁。
5. 密钥只由密码与文件夹中的盐派生，**不包含 Bundle ID、Team ID、设备 ID 或钥匙串数据**。忘记密码无法恢复；丢失/损坏索引或密文后需要从完整备份恢复。

## 文件格式与一致性

```text
SelectedFolder/
  image.jpg                  # 可直接在 Files 查看
  Album/video.mp4
  stream.movpkg/             # 系统 HLS 离线包
  .ptbrowser/
    library.json             # 仅普通媒体索引：收藏、导入哈希等
    vault.json               # v1、随机库 ID、盐、派生次数、AES-GCM 加密索引
    encrypted/<media UUID>/
      <blob UUID>.ptenc      # 不暴露原始文件名
```

`.ptenc` 格式：`PTBV0001` 8 字节魔数，随后多个 `UInt32 big-endian 密文长度 + UInt8 最终块标记 + AES-GCM combined(nonce/ciphertext/tag)`。AAD 绑定库 ID、媒体 ID、blob ID、块序号与最终标记。解密检查最终块、拒绝尾随数据，并校验明文字节数与 SHA-256。索引也使用 AES-GCM，AAD 绑定库 ID。

文件库操作在 actor 中串行执行，并在协调写入前重读磁盘索引；多安装实例修改同一个文件库时会合并最新状态。加密先写密文与原子提交加密索引，再清除普通索引并删除原件；失败时优先保留可恢复的数据。文件提供商可能发生网络中断或非原子同步，**跨设备同时编辑同一云端文件库仍可能产生提供商冲突副本，应避免同时写入**。不要手动删除 `.ptbrowser` 内部文件。

解密用于浏览时会在 App 的临时目录生成文件，使用完整文件保护，锁定/启动时清理；这属于本地文件加密，不提供取证级安全擦除，也无法阻止系统截图、录屏或已被攻陷的设备读取解锁内容。

## 支持范围

- 图片和音视频格式以当前 iOS 的 ImageIO / AVFoundation 能力为准，不包含转码器或第三方解码器。
- 嗅探无法穷尽任意网站：DRM、仅在内存存在的 Blob、MSE 专有分片、签名过期、验证码、防盗链和访问权限会限制下载。不会绕过 DRM 或网站权限。
- HLS 通道已实现，但实际离线可用性依赖服务器、系统 AVFoundation 与资源授权；直播、FairPlay 和其他 DRM 不支持，尚需使用目标站点在真机回归。
- 后台下载与恢复由 iOS 调度；强制划掉 App 可能中止传输。HLS 暂停是系统任务挂起，持久重启后可能需要重试；普通下载续传取决于服务器支持。
- 默认使用系统 WebKit 的 TLS 验证；网页 HTTP 与 HTTP 媒体允许加载。应用没有远程遥测或密钥上传。

## 验证与交付

测试覆盖加密往返、不同随机 nonce、错误密码、篡改/截断/尾随数据/文件交换、重新实例化文件库恢复、包文件加密、路径越界、文件管理、真实 loopback HTTP 下载与非法响应拒绝、DOM/动态媒体嗅探以及基本 UI 流程。`build/` 为本地构建产物，不提交版本库。

INGOO 的开发签名安装包只可安装到对应描述文件中登记的设备。正式分发还需要相应的 App Store / Ad Hoc 描述文件和设备/渠道配置。

使用本机已配置的 INGOO 开发证书和通配描述文件构建 IPA：

```sh
./scripts/build_ipa.sh
# 输出：build/Export/PTBrowser.ipa
```
