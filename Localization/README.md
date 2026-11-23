# Localization

`messages.json` is the editable source for English (`en`), Simplified Chinese (`zh-Hans`) and Japanese (`ja`). Apple apps use generated native String Catalogs; the JSON is not shipped as a runtime translation engine. English is the fallback. Language selection follows the operating system and its per-app language setting; restart the app after changing the language.

Keep message IDs stable, lowercase and semantic. Do not use translated strings as asset IDs, enum raw values, preference keys or persisted decisions. Each message declares its translator context and applicable platforms. Mark Photos/iCloud/Trash-specific messages Apple-only; a future Android app must supply its own permission, cloud and deletion wording. Android resources and UI are not implemented in this release.

Use complete sentences with named `{parameters}`, never concatenated fragments. Parameters declare `integer` or `text`, and translations must preserve all of them. Plural messages declare their first integer parameter as selector: English supplies `one` and `other`; Chinese and Japanese supply `other`. The exporter produces positional native format arguments so translations can reorder them. Escape literal braces as `{{` / `}}`; write percentages normally. Pass integer values as `Int64` and text as strings in Swift. Never pass user text as a format template.

| Meaning | English | 简体中文 | 日本語 |
| --- | --- | --- | --- |
| Manual keeper | Selected | 已选保留 | 残す写真に選択 |
| Algorithm suggestion | Recommended | 建议保留 | 推奨（残す） |
| Protected photo | Locked | 已锁定 | ロック済み |
| Confirmed removal candidate | Pending cleanup | 待清理 | 整理待ち |

These states have separate words and symbols. Selecting a keeper does not authorize deletion; cleanup still requires explicit confirmation. Known failures are translated from structured error cases. User filenames, album names, official license documents and explicitly labeled original system/scan diagnostics retain their original text. Numeric, byte-size and date formatting use native locale-aware formatters and retain unknown-value labels.

After editing the table:

```sh
python3 Tools/Localization/export.py
python3 -m unittest discover -s Tests/Localization
python3 Tools/Localization/export.py --check
```

Commit the source table and both generated catalogs together. Do not hand-edit generated catalogs. Checks reject duplicate IDs, missing languages, invalid parameters, malformed plurals and unknown Swift message references. Application tests verify that compiled native bundles resolve every applicable message and permission purpose in all three languages, including literal user text, plural counts and parameter reordering. UI tests cover language-specific review flows and restored decisions across language changes.

The exporter also checks static Swift message IDs and argument counts, including unqualified calls inside the error helper. This lexical check complements compiled resource tests; it does not validate every dynamic expression type or rendered glyph.
