# AlbumWinnow

[English](README.md) · [简体中文](README.zh-CN.md) · 日本語

AlbumWinnow は macOS、iOS、iPadOS 向けの写真整理アプリです。アクセスを許可した Apple の写真ライブラリと選択したフォルダから重複を探し、写真を見比べて残すものを選べます。macOS 26、iOS 26、iPadOS 26 以降に対応します。

## v1.7 の信頼性

利用できないフォルダ記録を再起動後も保持し、設定から再試行、再選択、明示的な削除ができます。保存済みの保護では個別のロック記録を管理でき、リンク先から継承したロックの解除は対象パスを確認します。保護を解除しても削除候補は復元されません。無効な判断だけを削除でき、有効な選択と保護は保持されます。

破損したファイル識別情報は整理を無効にします。状態データベースは schema 3 に移行し、判断を個別の行に、表示位置を別に保存します。旧版では新構造を読めないため、ダウングレード前にバックアップしてください。照合動作と有効な既存の判断署名は変わりません。

macOS の回帰テストは `Tests/run-macos-tests.sh`、公開手順は [Tools/Release](Tools/Release/README.md) を参照してください。macOS の公証や IPA の署名は別途必要です。

## v1.6.0 と言語

英語、簡体字中国語、日本語に対応しました。システムの優先言語、または OS のアプリ別言語設定に従います。言語を変更した後はアプリを開き直してください。未対応の言語では英語を使います。言語を変えても、手動の選択、ロック、比較範囲、整理待ちの計画は保持されます。

「残す写真に選択」は手動で選んだ写真、「推奨（残す）」はアルゴリズムの提案、「ロック済み」は必ず残す写真です。削除候補は「整理待ち」として区別します。ファイル名やアルバム名、公式ライセンス文書、原文と明示した診断情報は翻訳しません。

## 使い方と安全性

設定で写真へのアクセスを有効にするか、フォルダを追加してスキャンします。重複のグループを開き、写真と根拠を確認して残す写真を選びます。グループの確認後も、整理内容の確認画面で明示的に実行するまで写真は削除されません。再起動やスキャン完了による自動削除はありません。

削除直前に写真の変更、ロック、読み取り専用の出所、関連リソースを再確認します。対応する場合は「最近削除した項目」またはゴミ箱へ移動します。クラウド同期により他の端末にも変更が反映される場合があります。

似た写真の解析は初期状態では無効です。自然写真の注釈付きベンチマークによる精度は未測定です。差分プレビューは補助表示であり、違いが表示されないことは原本の同一性を保証しません。必ず写真を直接確認してください。

## ビルドとテスト

Xcode で `AlbumWinnow.xcodeproj` を開き、macOS は **AlbumWinnow**、iPhone／iPad は **AlbumWinnowMobile** を選びます。

```sh
swift test --package-path Packages/AlbumWinnowCore
python3 -m unittest discover -s Tests/Localization
python3 Tools/Localization/export.py --check
Tests/run-app-tests.sh SIMULATOR_UDID
```

UI テストには XcodeGen と標準の iOS シミュレータが必要です。生成した画像を使用するため、実機、自然写真ライブラリ、実際の iCloud アカウントでの検証を意味しません。翻訳の管理方法は [Localization](Localization/README.md)、機能の詳しい説明は [English README](README.md) を参照してください。Android アプリは本リリースに含まれません。

macOS 配布アプリは Apple Silicon／Intel 共通で、一時的な ad hoc 署名を使用します。iOS／iPadOS の IPA は未署名で、インストール前に署名が必要です。GitHub の正式リリースは [v1.0.0](https://github.com/WinstonMeursault/AlbumWinnow/releases/tag/v1.0.0) です。

[プライバシーポリシー](PRIVACY.md) · [AGPL-3.0 ライセンス](LICENSE) · [サードパーティ通知](THIRD-PARTY-NOTICES.txt)
