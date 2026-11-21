# AlbumWinnow

[English](README.md) · 简体中文

AlbumWinnow 是面向 macOS、iOS 和 iPadOS 的原生照片整理工具。应用可在系统照片图库和用户选定的文件夹中查找重复照片，推荐保留版本，并让用户在清理前逐组核对。

## 项目状态

AlbumWinnow 正在开发 v1.0。开发版面向 macOS 26、iOS 26、iPadOS 26 及以上版本，可扫描已授权的照片图库和文件夹，将重复照片分组，并支持核对后移入可恢复位置。

## 构建与运行

在 Xcode 中打开 `AlbumWinnow.xcodeproj`。运行 macOS 版时选择 **AlbumWinnow**，运行 iPhone 或 iPad 模拟器时选择 **AlbumWinnowMobile**。在 **Settings** 的 **Scan Sources** 分区启用照片图库或添加文件夹，再回到重复项页面点击 **Scan**。

也可以用 `swift build --package-path Packages/AlbumWinnowCore` 独立构建共享 Swift 包。

## 测试

在 macOS 26 或更高版本上选用 Xcode 26 或更高版本，直接运行核心回归测试。

```sh
swift test --package-path Packages/AlbumWinnowCore
```

随包图片均为生成的测试图集。测试覆盖字节一致、高位深图片、跨格式及跨分辨率匹配、局部变化、方向、增量扫描、取消、缓存恢复和测试副本的可恢复清理。GitHub Actions 在 Apple Silicon 和 Intel macOS 环境运行测试，并构建 macOS、iOS/iPadOS 应用。

应用回归测试覆盖核对与清理布局、大字体、后台删除校验、扫描恢复及当前核对交互。需要 XcodeGen 和已安装的 iOS 模拟器。请在专用模拟器运行，测试会自行生成文件夹素材：

```sh
Tests/run-app-tests.sh SIMULATOR_UDID
```

生成的测试工程放在 `.local`，预期版本号直接读取应用构建配置。测试不使用实机或 iCloud 账户。

## v1.0 范围

- 扫描系统照片图库和用户选定文件夹中的可访问照片，支持跨来源匹配。
- 识别完全重复的文件，以及同一画面在不同分辨率、压缩质量或编码格式下的副本，覆盖 HEIC、JPEG 和 PNG 等格式。
- 将匹配项分组供用户并排对比，结合画质、分辨率及 Live Photo 配对视频、编辑前原件等关联数据推荐保留版本。
- 复用未变化资源的指纹，每次扫描重建分组，并在允许清理前检查资源变化。

扫描会读取本地可用的图库资源，并在 Scan Issues 列出仅存于 iCloud 的照片。点击 **Download Pending Photos from iCloud** 可授权下载并重试这些项目。下载重试会重新读取所选资源，不因命中指纹缓存而跳过下载。重复项页面分别显示 iCloud 下载和扫描进度，并列出可用、失败和待处理数量。下载未全部完成时显示 **iCloud Download Incomplete**，并提示检查 Scan Issues。扫描结束后，重复项概览以瀑布流显示分组封面。点开一组即可在组内核对照片。在设置里打开 **Show Filenames in Review** 可显示文件名。详情页左滑进入下一组，右滑返回上一组。在 **Settings → Interaction → Group Transition** 中可选择平移、覆盖、淡化或无动画。点击想保留的照片后确认当前组，也可以跳过当前组。**Delete All** 会以红框预览整组删除。在 **Settings → Interaction → Review Button Layout** 中可以选择左手或右手布局，把确认按钮放在顺手的一侧。核对完成后，回到重复项概览，通过 **Confirm Cleanup** 检查并确认整批清理。在 iOS 和 iPadOS 上，因进入后台而中断的扫描会在回到前台后按已保存来源续扫，复用缓存指纹，并恢复此前已授权的待下载集合。主动取消会停止自动恢复。PhotoKit 提供具体错误时，Scan Issues 会保留系统错误说明、错误域和代码。扫描期间发生图库内容变化时，必须重新扫描后才能清理。更广泛的连拍分组等视觉相似照片整理功能计划在 v1.1 加入。

## 匹配与清理

| 类别 | 判定依据 | 清理行为 |
| --- | --- | --- |
| 完全重复 | 文件字节一致且有效方向相同。 | 沿用无额外相似标识的展示方式，确认后清理。 |
| 可能是同一画面 | 候选哈希与多尺度像素核验一致，允许分辨率、压缩质量或格式不同。 | 标明待核对，确认后可清理。 |
| 高度相似候选 | 粗略比较一致，但较高分辨率的核验发现局部差异。 | 标为 **Similar photos**，可在检查差异后人工确认清理。 |

匹配和索引在设备上执行，本地可用的照片支持离线扫描。每次清理均需用户明确确认。确认后，图库照片移入「最近删除」，目录文件移入可用的文件系统回收站。文件提供方缺少回收站时，应用会保留原文件，并在本次操作结果中显示失败。当前版本禁止清理带有 Live Photo 视频、编辑数据或替代照片资源的图库项目。文件夹图片存在同名 MOV/MP4/M4V 视频、AAE/XMP 旁文件或 RAW/渲染图配对时，也采用保守保护；清理前会重新检测扫描后新增的关联文件。这项基于文件名的保护不能覆盖所有导出命名规则。本次清理结果页显示跳过或失败项目的预览与原因，不保存清理历史。

## 技术设计

`AlbumWinnowCore` 以 Swift Package 形式供各平台的 SwiftUI 应用共享。PhotoKit 和 Foundation 分别用于访问系统图库和文件。BLAKE3 判断文件字节是否一致，文件夹资源采用流式读取。ImageIO 生成受限尺寸的缩略图，提供 pHash 和 dHash 候选，再通过多尺度像素核验区分同画面候选与存在局部差异的高度相似项。推荐算法保留原始分辨率并考虑位深。SQLite 和 GRDB 存储增量指纹，损坏缓存项会重新生成；下一次扫描完成后回收不再使用的来源缓存。Swift Concurrency 限制并行图片处理数量。详情与清理预览和概览缩略图共用按大小计费的队列：最多四个小请求，大文件或大小未知的图库预览单独执行。文件提供方允许时，文件夹预览使用安全文件映射，避免额外复制整份文件到堆内存；ImageIO 将解码预览限制在 1024 像素。**Settings → Storage → Clear Scan Cache** 可删除指纹缓存并压缩数据库以释放磁盘空间，保留照片与来源授权；下一次扫描将重新读取照片。

## 实现与验证状态

识别核心、文件夹扫描、增量缓存、PhotoKit 接入、SwiftUI 核对、可恢复清理及 iOS/iPadOS 布局均已实现。候选检索采用按汉明距离分段的多索引。当前匹配使用感知哈希与多尺度像素核验，没有使用 Vision 特征向量。

`Tests/Performance` 提供确定性的全分辨率 JPEG 生成器及调用实际扫描引擎的基准程序。覆盖冷扫、未变化扫描、1% 资源变化和取消后的缓存恢复，并逐一核对已知重复配对。在新的本地目录生成素材：

```sh
python3 -m venv .local/performance-venv
.local/performance-venv/bin/pip install Pillow
.local/performance-venv/bin/python Tests/Performance/generate_photos.py --root .local/benchmark-10000 --count 10000
swift run --package-path Tests/Performance -c release ScanBenchmark .local/benchmark-10000 10000 .local/benchmark-10000/results.json
```

较大规模将数量改为 50000 或 100000，使用新目录，并预留磁盘空间。每张图片为 4032 × 3072，10 万张素材及两份指纹缓存约需 50 GB。RSS 为进程累计峰值；冷扫仅表示应用缓存为空，不会清空文件系统缓存。合成图用于验证规模和已知完全重复配对，不能代表自然照片识别准确率或 PhotoKit 端到端速度。

v1.0 发布前仍需针对实际账户验证 iCloud 传输、网络失败和前后台切换。自动化测试在没有 iCloud 账户的条件下覆盖请求回调、取消竞争、错误传递及图库变化处理。更广泛的自然照片准确率和各类设备性能属于独立验收工作。

## 许可证

公开源码采用 GNU Affero General Public License 第 3 版。详见 [许可证](LICENSE)与[第三方许可声明](THIRD-PARTY-NOTICES.txt)。

[隐私政策](PRIVACY.md)说明图库访问、iCloud 下载与设备上的数据保存方式。
