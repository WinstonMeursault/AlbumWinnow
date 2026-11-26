# AlbumWinnow

[English](README.md) · [简体中文](README.zh-CN.md) · 日本語

AlbumWinnow は macOS、iOS、iPadOS 向けの写真整理アプリです。アクセスを許可した Apple の写真ライブラリと選択したフォルダから重複を探し、写真を見比べて残すものを選べます。macOS 26、iOS 26、iPadOS 26 以降に対応します。

[リリースノート](CHANGELOG.md)

## アーキテクチャと対応環境

AlbumWinnow v2.0.1 の Apple アプリは Rust Core と Swift/SwiftUI を採用しています。英語、簡体字中国語、日本語に対応します。リポジトリには Kotlin バインディングと最小 Android 検証ホストも含まれます。本バージョンには完全な Android クライアントや Windows/Linux アプリは含まれません。

v2 は出所・写真の識別子、確認・キャッシュ用データベース、署名、設定を独立させます。更新後は出所と保護を設定し直して再スキャンしてください。v1 のデータを移行・自動削除せず、削除候補も復元しません。既存のアプリ bundle ID は維持します。

通常の再起動後は手動でスキャンすると、現在の資源と一致する確認済み v2 計画を復元します。再起動だけではスキャンや写真の削除を開始しません。バックグラウンド移行で中断したスキャンは保存済みの同意で再開できますが、明示的なキャンセルは自動再開を停止します。

## 信頼性

利用できないフォルダ記録を再起動後も保持し、設定から再試行、再選択、明示的な削除ができます。保存済みの保護では個別のロック記録を管理でき、リンク先から継承したロックの解除は対象パスを確認します。保護を解除しても削除候補は復元されません。無効な判断だけを削除でき、有効な選択と保護は保持されます。

v2 の保護情報が利用できない、または破損した場合は整理を無効にします。Rust が判断、出所の保護、確認位置を v2 データベースのトランザクションで保存し、位置は独立したシーケンスを使用します。確認状況をリセットしても v2 のロックと出所の保護は残ります。v1 データベースや署名は開かず、移行もしません。

macOS の回帰テストは `Tests/run-macos-tests.sh`、公開手順は [Tools/Release](Tools/Release/README.md) を参照してください。macOS の公証や IPA の署名は別途必要です。

## 言語

英語、簡体字中国語、日本語に対応しました。システムの優先言語、または OS のアプリ別言語設定に従います。言語を変更した後はアプリを開き直してください。未対応の言語では英語を使います。言語を変えても、手動の選択、ロック、比較範囲、整理待ちの計画は保持されます。

「残す写真に選択」は手動で選んだ写真、「推奨（残す）」はアルゴリズムの提案、「ロック済み」は必ず残す写真です。削除候補は「整理待ち」として区別します。ファイル名やアルバム名、公式ライセンス文書、原文と明示した診断情報は翻訳しません。

## 使い方と安全性

設定で写真へのアクセスを有効にするか、フォルダを追加してスキャンします。重複のグループを開き、写真と根拠を確認して残す写真を選びます。グループの確認後も、整理内容の確認画面で明示的に実行するまで写真は削除されません。再起動やスキャン完了による自動削除はありません。

削除直前に写真の変更、ロック、読み取り専用の出所、関連リソースを再確認します。対応する場合は「最近削除した項目」またはゴミ箱へ移動します。クラウド同期により他の端末にも変更が反映される場合があります。

似た写真の解析は初期状態では無効です。自然写真の注釈付きベンチマークによる精度は未測定です。差分プレビューは補助表示であり、違いが表示されないことは原本の同一性を保証しません。必ず写真を直接確認してください。

## ビルドとテスト

rustup の固定 Rust ツールチェーンと完全な Xcode を準備し、Swift パッケージを解決する前にネイティブライブラリを生成します。

```sh
Tools/Core/build-apple.sh debug
```

その後 Xcode で `AlbumWinnow.xcodeproj` を開き、macOS は **AlbumWinnow**、iPhone／iPad は **AlbumWinnowMobile** を選びます。

```sh
cargo test --workspace --locked
swift test --package-path Packages/AlbumWinnowRust
swift test --package-path Packages/AlbumWinnowApple
python3 -m unittest discover -s Tests/Localization
python3 Tools/Localization/export.py --check
Tests/run-app-tests.sh SIMULATOR_UDID
```

UI テストには XcodeGen と標準の iOS シミュレータが必要です。生成した画像を使用するため、実機、自然写真ライブラリ、実際の iCloud アカウントでの検証を意味しません。翻訳の管理方法は [Localization](Localization/README.md)、機能の詳しい説明は [English README](README.md) を参照してください。ネイティブライブラリの各 slice、バインディング、Android smoke 検証は [Core ビルド手順](Tools/Core/README.md) を参照してください。開発中は変更に必要な検証だけを選び、候補の納品前に全マトリクスとクリーンビルドを実行します。

## 構成

Rust が指紋、分類、重複・場面のグループ化、推奨、確認状態、出所・別名の保護、SQLite 保存、一時的な整理許可を管理します。UniFFI が Swift/Kotlin を接続し、Apple 側は PhotoKit/Foundation、ImageIO/Core Image、Vision 測定、ブックマークと OS の復元可能な移動を担当します。SwiftUI は有界の概要と必要なグループ詳細だけを読みます。既存の照合規則、手動確認、保護の意味を維持します。

[移行カバレッジ](Tools/Core/TEST-COVERAGE.md)に既存の検証の移行先を記録しています。依存関係の通知は `python3 Tools/Core/notices.py` で生成し、`--check` で照合します。macOS は Apple Silicon／Intel の universal ビルドに対応し、ad hoc 署名と未署名 IPA の扱いは [公開手順](Tools/Release/README.md) を参照してください。配布物は [GitHub Releases](https://github.com/WinstonMeursault/AlbumWinnow/releases) から取得できます。

[プライバシーポリシー](PRIVACY.md) · [AGPL-3.0 ライセンス](LICENSE) · [サードパーティ通知](THIRD-PARTY-NOTICES.txt)
