# AlbumWinnow v2.0.1

2026-11-26

## 升级须知

v2 使用独立的来源/照片身份、核对与缓存数据库、签名和偏好，不兼容 v1 数据。升级后请重新设置来源与保护并扫描；不会导入旧删除候选，也不会自动删除旧数据。日常重启后，手动扫描才会恢复与当前资源仍一致的已确认 v2 计划；所有清理仍需人工确认。

## 架构与功能

Apple 应用采用 Rust Core + Swift/SwiftUI：Rust 统一负责识别、分组、推荐、核对状态、SQLite 存储和清理授权，Apple 端负责 PhotoKit、解码、Vision、书签授权与系统可恢复操作。保留既有识别规则、保护语义、iPhone/iPad/macOS 功能和英文、简体中文、日语界面。本次统一用户文档、构建说明、接口合同及测试覆盖说明，移除过期的开发阶段文字。同时修正 CI 环境依赖、跨工具链的测试资源打包和授权测试入口，保留原测试断言。

仓库提供生成的 Swift/Kotlin 绑定及最小 Android 验证宿主；Android 组件用于核心接入验证，不是完整照片客户端。本版不包含 Windows/Linux 应用。

## 下载与验证范围

macOS 提供 Apple Silicon/Intel 通用 ZIP，采用临时签名、未公证；iOS/iPadOS IPA 未签名，需要自行签名安装。Apple 最低系统版本均为 26。Android 验证组件包含双 ABI 核心、Kotlin 绑定与仪器测试宿主，最低 API 26。

自动化覆盖固定生成图片、原生 Photos 测试素材、状态故障、保护与人工确认路径。自然照片识别准确率和真实 iCloud 账户传输没有据此得到验证。Android 16 KB 为 ELF/ZIP 静态兼容检查，实际模拟器使用 4 KB 系统页。

## English

The Apple applications use Rust Core with native Swift/SwiftUI services, preserving the existing recognition rules, manual confirmation and protection semantics. Documentation, build instructions, contracts and the regression coverage map now describe the current implementation. Kotlin bindings and a minimal Android validation host are included; a complete Android client and Windows/Linux applications are outside this release.

**Breaking upgrade:** v2 starts with separate identities, databases, signatures and preferences. Reconfigure sources and protection and scan again. v1 data is not migrated or automatically deleted, and old deletion candidates are not imported. After an ordinary relaunch, a manual scan restores only still-valid confirmed v2 plans.

Apple platforms require OS 26 or later. The macOS ZIP is universal and ad hoc signed, without notarization. The iOS/iPadOS IPA is unsigned and requires signing. Generated fixtures and controlled cloud-policy tests do not establish natural-photo accuracy or actual iCloud-account transfer behavior.
