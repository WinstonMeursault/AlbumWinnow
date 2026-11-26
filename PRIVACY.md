# AlbumWinnow Privacy Policy

Effective November 26, 2026

AlbumWinnow is developed by Winston Meursault. AlbumWinnow processes photos on your device. The app has no account system, advertising, analytics, or developer-operated service that collects photos or scan results.

- **Access.** The app reads photos you authorize in Apple Photos and files in folders you select. It uses image data and metadata to find duplicates, display previews, and check that an item has not changed before cleaning it up.
- **Local storage.** The app stores preferences, folder permissions, source/photo and album identifiers, album titles, capture-date ranges, source preferences, pending download consent, scan group metadata and resource revisions, review decisions, locks/read-only physical identities, review position, fingerprints, comparison samples, optional Vision scene features and focus/exposure measurements on your device. Rust stores scan groups and review/protection records in a local review database; derived image data has a separate cache database. v2 uses separate databases, identities, signatures and preferences: it does not migrate, open or automatically delete v1 records or restore their deletion candidates. Configure sources and protection again and rescan after upgrading. Clear Scan Cache removes derived cache data while retaining photos, permissions and review/protection records. Reset Review Progress clears decisions and position while retaining locks and source protection. Unavailable folder bookmarks and source protection remain until you explicitly remove or update them. Removing protection never restores deletion candidates. Current cleanup outcomes remain in memory and are not saved as history. Removing a source or revoking access prevents future scans. To remove existing local records, delete the app and its data; on macOS, deleting the app alone may leave data in your Library.
- **Difference previews.** The explicitly selected comparison pair is processed on your device using bounded previews. Difference annotations remain in memory and are cleared when the pair changes, the comparison view closes, or the app backgrounds. They are not uploaded or stored as review history.
- **Cloud photos and folders.** If you disable the default skip-cloud setting or authorize a one-scan download of pending iCloud photos, the app asks Apple Photos to retrieve them. Apple handles the transfer under its own privacy policy. The app does not upload photos to the developer. Files in folders managed by iCloud Drive or another provider remain subject to that provider’s synchronization settings and terms.
- **Cleanup.** After you confirm, the app asks Photos or the file system to move the selected items to Recently Deleted or Trash when supported. With iCloud Photos or a synced folder, the provider may synchronize those changes to your other devices.
- **External links.** Opening the source code, privacy policy, or support link takes you to GitHub. GitHub handles those visits under its own privacy policy.

For privacy questions, contact the developer via the [AlbumWinnow repository](https://github.com/WinstonMeursault/AlbumWinnow/issues). Please do not post photos, file paths, or other private information in a public issue.

## AlbumWinnow 隐私政策

生效日期：2026 年 11 月 26 日

AlbumWinnow 由 Winston Meursault 开发，在设备上处理照片。应用没有账号系统、广告、分析统计，也没有由开发者运营的照片或扫描结果收集服务。

- **访问权限。** 应用读取你授权访问的 Apple 照片和你选定文件夹中的文件。图片和元数据用于识别重复项、显示预览，以及清理前检查项目是否发生变化。
- **本地保存。** 应用在设备上保存设置、文件夹授权、来源/照片与相册标识、相册标题、拍摄日期范围、来源偏好、待下载授权、扫描分组元数据与资源版本、人工决定、锁定与只读物理身份、核对位置、指纹、比对样本、可选 Vision 场景特征及清晰度/曝光测量。Rust 将扫描分组和核对/保护记录写入本地核对数据库，派生图片数据使用独立缓存数据库。v2 使用独立数据库、身份、签名与偏好，不迁移、读取或自动删除 v1 记录，也不恢复其删除候选；升级后需重新设置来源与保护并扫描。Clear Scan Cache 清除派生缓存并保留照片、授权、核对与保护；Reset Review Progress 清除决定和位置，保留锁与来源保护。不可用来源书签和保护保留到你明确移除或更新，解除保护不会恢复删除候选。本次清理结果保存在内存，不保存为历史。移除来源或撤销授权可阻止后续扫描。移除已有本地记录需要删除应用及其数据；macOS 仅删除应用可能在资源库中留下数据。
- **差异预览。** 应用仅在设备上处理你明确选择的比较照片，使用有界尺寸预览。差异标注保存在内存，更换比较照片、退出比较页面或切到后台时清除，不上传，也不保存为核对历史。
- **云端照片和文件夹。** 你关闭默认的跳过云端照片设置，或授权单次下载待处理的 iCloud 照片时，应用会请求 Apple 照片取回资源，传输由 Apple 按其隐私政策处理。应用不会把照片上传给开发者。iCloud 云盘或其他文件提供方管理的目录仍受该服务的同步设置和条款约束。
- **清理。** 你确认后，应用会请求照片图库或文件系统将选定项目移入「最近删除」或废纸篓。开启 iCloud 照片或使用同步目录时，服务方可能把变更同步到你的其他设备。
- **外部链接。** 源码、隐私政策和支持链接会打开 GitHub。GitHub 按其隐私政策处理这些访问。

如有隐私问题，请通过 [AlbumWinnow 仓库](https://github.com/WinstonMeursault/AlbumWinnow/issues)联系开发者。请勿在公开议题中发布照片、文件路径或其他私人信息。

## AlbumWinnow プライバシーポリシー

施行日：2026 年 11 月 26 日

AlbumWinnow は Winston Meursault が開発し、端末上で写真を処理します。アカウント、広告、アクセス解析、開発者が写真やスキャン結果を収集するサービスはありません。

- **アクセス。** 許可された Apple の写真と、選択したフォルダのファイルを読み取ります。画像とメタデータは重複の検出、プレビュー、整理直前の変更確認に使います。
- **端末内の保存。** 設定、フォルダ許可、出所・写真・アルバムの識別子、アルバム名、撮影日範囲、出所の優先順位、保留中のダウンロード許可、スキャングループのメタデータと資源の版、手動判断、ロック・読み取り専用の物理識別情報、確認位置、指紋、比較サンプル、任意の Vision 特徴量と鮮明度・露出の測定値を端末に保存します。Rust がグループと確認・保護をローカル確認データベースに保存し、派生画像データは別のキャッシュに保存します。v2 はデータベース、識別子、署名、設定を独立させ、v1 の記録を移行・読み込み・自動削除せず、削除候補も復元しません。更新後は出所と保護を設定し直して再スキャンしてください。キャッシュ消去は写真、許可、確認・保護を残します。確認状況のリセットは判断と位置を消去し、ロックと出所の保護を残します。利用できないブックマークと保護は明示的に削除・更新するまで保持し、保護の解除で削除候補を復元しません。今回の整理結果はメモリ内だけで、履歴に保存しません。出所の削除やアクセス撤回は今後のスキャンを停止します。保存済み情報を消去するにはアプリとデータを削除してください。macOS はアプリのみ削除してもライブラリ内にデータが残る場合があります。
- **差分プレビュー。** 明示的に選んだ写真を、サイズを制限したプレビューで端末内処理します。注釈はメモリ内のみで、写真の組を変えたとき、比較画面を閉じたとき、バックグラウンドに移ったときに消えます。アップロードや履歴保存は行いません。
- **クラウド。** 初期設定のクラウド写真をスキップする設定を無効にするか、今回だけのダウンロードを許可すると、Apple の写真に取得を依頼します。転送には Apple のプライバシーポリシーが適用されます。開発者への写真のアップロードはありません。iCloud Drive などの同期フォルダは各サービスの設定と規約に従います。
- **整理。** 確認後、対応している場合は写真を「最近削除した項目」またはゴミ箱へ移動するよう依頼します。iCloud 写真や同期フォルダでは、他の端末にも変更が反映される場合があります。
- **外部リンク。** ソースコード、プライバシーポリシー、サポートを開くと GitHub に移動します。GitHub のプライバシーポリシーが適用されます。

お問い合わせは [AlbumWinnow リポジトリ](https://github.com/WinstonMeursault/AlbumWinnow/issues)へ。公開の Issue に写真、ファイルパス、個人情報を投稿しないでください。
