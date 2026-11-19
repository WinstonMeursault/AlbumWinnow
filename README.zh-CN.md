# AlbumWinnow

[English](README.md) · 简体中文

AlbumWinnow 是面向 macOS、iOS 和 iPadOS 的原生照片整理工具。项目计划在系统照片图库和用户选定的文件夹中查找重复照片，推荐保留版本，并让用户在清理前逐组核对。

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
- 复用未变化资源的扫描结果，在照片新增、编辑或删除后更新索引。

扫描会读取本地可用的图库资源，并在 Scan Issues 列出仅存于 iCloud 的照片。点击 **Download Pending Photos from iCloud** 可授权下载并重试这些项目。重复项页面分别显示 iCloud 下载和扫描进度，并列出可用、失败和待处理数量。扫描结束后，重复项概览以瀑布流显示分组封面。点开一组即可在组内核对照片。在设置里打开 **Show Filenames in Review** 可显示文件名。详情页左滑进入下一组，右滑返回上一组。在 **Settings → Interaction → Group Transition** 中可选择平移、覆盖、淡化或无动画。点击想保留的照片后确认当前组，也可以跳过当前组。**Delete All** 会以红框预览整组删除。在 **Settings → Interaction → Review Button Layout** 中可以选择左手或右手布局，把确认按钮放在顺手的一侧。核对完成后，回到重复项概览，通过 **Confirm Cleanup** 检查并确认整批清理。在 iOS 和 iPadOS 上，中断的扫描会在回到前台后按已保存来源续扫，并复用缓存的指纹。更广泛的连拍分组等视觉相似照片整理功能计划在 v1.1 加入。

## 匹配与清理

| 类别 | 判定依据 | 清理行为 |
| --- | --- | --- |
| 完全重复 | 文件字节一致且有效方向相同。 | 沿用无额外相似标识的展示方式，确认后清理。 |
| 可能是同一画面 | 候选哈希与多尺度像素核验一致，允许分辨率、压缩质量或格式不同。 | 标明待核对，确认后可清理。 |
| 高度相似候选 | 粗略比较一致，但较高分辨率的核验发现局部差异。 | 标为 **Similar photos**，可在检查差异后人工确认清理。 |

匹配和索引在设备上执行，本地可用的照片支持离线扫描。每次清理均需用户明确确认。确认后，图库照片移入「最近删除」，目录文件移入可用的文件系统回收站。文件提供方缺少回收站时，应用会保留原文件，并在本次操作结果中显示失败。

## 技术设计

`AlbumWinnowCore` 以 Swift Package 形式供各平台的 SwiftUI 应用共享。PhotoKit 和 Foundation 分别用于访问系统图库和文件。BLAKE3 判断文件字节是否一致，文件夹资源采用流式读取。ImageIO 生成受限尺寸的缩略图，提供 pHash 和 dHash 候选，再通过多尺度像素核验区分同画面候选与存在局部差异的高度相似项。推荐算法保留原始分辨率并考虑位深。SQLite 和 GRDB 存储增量指纹，损坏缓存项会重新生成；下一次扫描完成后回收不再使用的来源缓存。Swift Concurrency 限制并行图片处理数量。

## 开发路线

1. 实现重复识别原型，使用带标注的图片对验证分类。首项验收使用同一画面的 4032 × 3024 和 1280 × 960 两个版本，分别采用不同编码，验证两者能否归为同一画面。同一连拍中有内容差异的帧须排除在重复项清理结果之外。
2. 实现 macOS 文件夹扫描、候选索引和增量缓存。
3. 接入 PhotoKit，跟踪图库变化，并处理 Live Photo 和 iCloud 资源。
4. 使用 SwiftUI 实现 macOS 上的分组核对与清理流程。
5. 适配 iOS 和 iPadOS 的权限、后台执行限制和界面布局。
6. 对 1 万、5 万和 10 万张照片测量扫描耗时、峰值内存和匹配准确率，在发布前验证两类来源的清理流程。

单次扫描的设计目标为 10 万张照片，性能验证安排在最后一个阶段。

## 许可证

公开源码采用 GNU Affero General Public License 第 3 版。详见 [许可证](LICENSE)与[第三方许可声明](THIRD-PARTY-NOTICES.txt)。

[隐私政策](PRIVACY.md)说明图库访问、iCloud 下载与设备上的数据保存方式。
