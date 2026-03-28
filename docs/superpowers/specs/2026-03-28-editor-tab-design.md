# Editor Tab Design Spec

## Overview

cmux にビルトインのエディタータブを追加する。ファイルエクスプローラーで選んだファイルをアプリ内で閲覧・軽編集できるメモ帳的なパネル。コードを書くためではなく、Markdown / JSON / 設定ファイルなどをさっと見て編集するユースケースが主。

## Architecture

### New Panel Type

`PanelType.editor` を追加。既存の MarkdownPanel パターンを踏襲する。

**新規ファイル:**

| File | Role |
|------|------|
| `Sources/Panels/EditorPanel.swift` | パネルモデル。ファイル読み込み、保存、ファイル監視、isDirty 管理 |
| `Sources/Panels/EditorPanelView.swift` | SwiftUI ビュー。ツールバー + エディタ本体 |
| `Sources/Panels/EditorTextView.swift` | NSViewRepresentable。NSTextView をラップ |
| `Sources/Panels/SyntaxHighlighter.swift` | 正規表現ベースの軽量シンタックスハイライト |

**変更ファイル:**

| File | Change |
|------|--------|
| `Sources/Panels/Panel.swift` | `PanelType` に `.editor` 追加 |
| `Sources/Panels/PanelContentView.swift` | `.editor` ケースのルーティング追加 |
| `Sources/Workspace.swift` | `newEditorSurface()` ファクトリメソッド + 一時タブ管理 |
| `Sources/SessionPersistence.swift` | `SessionEditorPanelSnapshot` 追加 |
| `Sources/Panels/FileExplorerPanelView.swift` | シングルクリック/ダブルクリック連携 |
| `Sources/Panels/FileExplorerOutlineView.swift` | シングルクリック callback 追加 |
| `Sources/Panels/FileExplorerDataSource.swift` | シングルクリックハンドラ追加 |
| `Sources/TerminalController.swift` | `editor.open` ソケットコマンド追加 |

### EditorPanel

```
EditorPanel: ObservableObject, Panel
├── filePath: String
├── content: String (@Published)
├── isDirty: Bool (@Published)
├── isPreview: Bool (@Published)  // 一時タブかどうか
├── language: EditorLanguage (@Published)
├── displayTitle: String  // ファイル名
├── displayIcon: String?  // 拡張子に応じたアイコン
├── save()  // ファイル書き込み、isDirty → false
├── reload()  // ファイル再読み込み
├── promoteToFixed()  // 一時タブ → 固定タブ
└── close()  // ファイル監視停止、リソース解放
```

**ファイル監視:** DispatchSource で .write, .delete, .rename, .extend を監視。外部変更時にリロード（isDirty でなければ自動、isDirty なら通知のみ）。

**バイナリ判定:** ファイルの先頭 8KB を読み、NUL バイト (0x00) が含まれていればバイナリと判定。バイナリの場合は EditorPanel を作らず `NSWorkspace.shared.open` にフォールバック。

### EditorPanelView

```
EditorPanelView
├── Toolbar
│   ├── ファイル名ラベル (イタリック = 一時タブ)
│   └── 言語表示ラベル
├── Divider
└── EditorTextView (NSViewRepresentable)
    └── NSTextView
        ├── 編集可能
        ├── シンタックスハイライト (NSAttributedString)
        └── Cmd+S → save()
```

### EditorTextView (NSViewRepresentable)

NSTextView を NSScrollView 内でラップ。

- テキスト変更を `EditorPanel.content` に反映
- テキスト変更時に `isDirty = true`
- テキスト変更時に `isPreview` なら `promoteToFixed()`
- `SyntaxHighlighter` で着色を適用
- Cmd+S をキーイベントでインターセプトして `save()` を呼ぶ

### SyntaxHighlighter

正規表現ベースの軽量ハイライト。言語ごとにパターンセットを定義。

**対応言語 (初回):**

| Language | Extensions | Highlight targets |
|----------|-----------|-------------------|
| JSON | .json | keys, strings, numbers, booleans, null |
| Markdown | .md | headers, bold, italic, code, links |
| Swift | .swift | keywords, strings, numbers, comments |
| YAML | .yaml, .yml | keys, values, comments |
| TOML | .toml | keys, values, sections, comments |
| Generic | その他 | strings, numbers, comments (// and #) |

**着色タイミング:** テキスト変更時にバックグラウンドで着色を計算し、メインスレッドで適用。大量入力時はデバウンス（200ms）。

### EditorLanguage

```swift
enum EditorLanguage: String, Codable, Sendable {
    case json, markdown, swift, yaml, toml, generic

    init(from extension: String) { ... }
}
```

## File Explorer Integration

### Click Behavior

| Action | Result |
|--------|--------|
| シングルクリック (ファイル) | 一時タブで開く（既存の一時タブを再利用） |
| ダブルクリック (ファイル) | 固定タブで開く |
| シングルクリック (ディレクトリ) | 展開/折りたたみ (変更なし) |
| ダブルクリック (ディレクトリ) | 展開/折りたたみ (変更なし) |

### Preview Tab (一時タブ) Rules

1. ワークスペースに一時エディタタブは最大 1 つ
2. シングルクリックで別ファイルを選ぶ → 既存の一時タブを差し替え
3. 一時タブで編集を始める → 自動的に固定タブに昇格 (`promoteToFixed()`)
4. ダブルクリック → 直接固定タブとして開く
5. 同じファイルが固定タブで既に開いている → そのタブにフォーカス移動
6. 一時タブのタブタイトルはイタリック表示で区別

### Binary File Handling

バイナリファイルの場合はエディタタブを作らず、従来通り `NSWorkspace.shared.open` で OS デフォルトアプリに委譲する。

## Session Persistence

```swift
struct SessionEditorPanelSnapshot: Codable {
    var filePath: String
    var isPreview: Bool
    var cursorPosition: Int?  // optional, best-effort
}
```

セッション復元時に `isPreview: true` のタブはファイルが存在しなければ静かにスキップ。

## Socket API

### `editor.open`

```json
{
    "file_path": "/path/to/file.json",
    "preview": true,
    "focus": true
}
```

- `file_path` (required): 開くファイルのパス
- `preview` (optional, default: false): true なら一時タブとして開く
- `focus` (optional, default: true): タブにフォーカスを移すか

## Focus Management

`PanelFocusIntent` に `.editor(EditorPanelFocusIntent)` を追加。

```swift
enum EditorPanelFocusIntent: Codable, Sendable {
    case textView
}
```

初回は textView のみ。将来的に検索フィールドなどが追加されたら拡張。

## Out of Scope

- 検索/置換 (Cmd+F)
- 行番号表示
- タブ/スペース設定
- エンコーディング選択 (UTF-8 固定)
- 大ファイル対応 (数MB超)
- TreeSitter ベースの高精度ハイライト
- 複数カーソル
- ミニマップ
