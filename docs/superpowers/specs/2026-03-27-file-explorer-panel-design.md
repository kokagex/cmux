# File Explorer Panel — Design Spec

## Overview

VS Code ライクなファイルエクスプローラーを cmux のパネルタブとして追加する。ターミナルやブラウザと同様に、タブの一つとして開き、分割表示も可能。

## Decisions

| 項目 | 決定 |
|------|------|
| 表示形式 | パネルタブ（サイドバーではない） |
| ルートディレクトリ | デフォルトはワークスペースCWD、手動変更可 |
| ファイルオープン動作 | 設定で選択可（editor / builtin / system） |
| UI実装 | NSOutlineView（NSViewRepresentable ラップ） |
| アイコン | SF Symbols ベースのモノクロアイコン |

## Scope

### In scope (v1)

- ツリー表示（フォルダ展開/折りたたみ、遅延ロード）
- SF Symbols によるファイル/フォルダアイコン
- `.gitignore` 対応（無視ファイルを非表示、トグルで表示可）
- ファイル/フォルダの新規作成・削除・リネーム
- ドラッグ&ドロップでファイル/フォルダ移動
- ファイル検索/フィルター（インクリメンタルサーチ）
- Git ステータス表示（変更ファイルの色分け）
- セッション永続化（展開状態、設定を保存復元）

### Out of scope

- ファイルプレビュー（ホバー/クイックルック）
- マルチルート（複数ルートを1つのツリーに表示）
- ファイル差分表示
- リモートファイルシステム

## Architecture

### New files

```
Sources/Panels/
  FileExplorerPanel.swift          — Panel プロトコル実装 (ObservableObject)
  FileExplorerPanelView.swift      — SwiftUI ホスト (ツールバー + NSViewRepresentable)
  FileExplorerOutlineView.swift    — NSOutlineView ラッパー (NSViewRepresentable)
  FileExplorerDataSource.swift     — NSOutlineViewDataSource + Delegate
  FileNode.swift                   — ツリーノードモデル
  FileIconMapper.swift             — 拡張子 → SF Symbol マッピング
  GitStatusProvider.swift          — git status --porcelain パーサー
```

### Modified files

- `Panel.swift` — `PanelType` に `.fileExplorer` 追加
- `PanelContentView.swift` — ルーティング追加
- `Workspace.swift` — `newFileExplorerSplit()` / `newFileExplorerSurface()` 追加
- `SessionPersistence.swift` — `SessionFileExplorerPanelSnapshot` 追加
- `ContentView.swift` — コマンドパレット対応、キーボードショートカット

### Data flow

```
FileExplorerPanel (ObservableObject)
  ├── rootPath: String (Published)
  ├── fileNodes: [FileNode] (ツリーデータ)
  ├── gitStatuses: [String: GitStatus]
  └── FSEventStream → ファイル変更検知 → ツリー差分更新

FileExplorerOutlineView (NSViewRepresentable)
  ├── NSOutlineView + DataSource/Delegate
  ├── ドラッグ&ドロップ (NSPasteboardItem)
  └── コンテキストメニュー (新規/削除/リネーム)
```

## Data Model

### FileNode

```swift
class FileNode: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?      // nil = 未ロード, [] = 空ディレクトリ
    var isExpanded: Bool = false
    var gitStatus: GitStatus = .unmodified
}
```

- ディレクトリは遅延ロード（展開時に子ノードを読み込む）
- ソート順: ディレクトリ優先 → アルファベット順
- `.gitignore` フィルタ: `git check-ignore -z --stdin` にパスを渡して判定。ネストした `.gitignore` も git が正しく処理する。隠しファイルもデフォルト非表示、トグルで表示可

### GitStatus

```swift
enum GitStatus {
    case unmodified
    case modified    // 黄
    case added       // 緑
    case deleted     // 赤
    case untracked   // 灰
    case conflicted  // オレンジ
}
```

- `git status --porcelain=v1 -z` をバックグラウンドで実行しパース
- FSEvent で変更検知 → git status を再実行（デバウンス 500ms）

## File System Watching

- `FSEventStream` (CoreServices) でディレクトリツリー全体をウォッチ
- 変更イベント → 該当ノードの子を再スキャン → NSOutlineView を差分リロード（`reloadItem(_:reloadChildren:)`）
- デバウンス: 100ms で連続イベントをまとめる
- MarkdownPanel の `DispatchSourceFileSystemObject` は単一ファイル向きなので、ディレクトリツリーには FSEventStream を使用

## UI Layout

### Toolbar

```
[📁 ~/projects/cmux] [🔍 フィルター...] [⋯]
```

- パンくず: 現在のルートパスを表示。クリックで NSOpenPanel からルート変更
- フィルター: インクリメンタルサーチ。入力するとツリーをフラット化してマッチするファイルだけ表示
- `⋯` メニュー: 隠しファイル表示トグル、gitignore 無視ファイル表示トグル、全フォルダ折りたたみ/展開

### Tree view

- NSOutlineView の標準ディスクロージャ三角（▶/▼）でフォルダ展開
- 各行: `[アイコン] [ファイル名] [Gitステータスバッジ]`
- アイコン: SF Symbols。FileIconMapper で拡張子ごとにマッピング
- シングルクリック = 選択、ダブルクリック = ファイルを開く（設定に従う）
- 行の高さ: 22pt

### Context menu (right-click)

- 新規ファイル / 新規フォルダ
- リネーム（インライン編集）
- 削除（ゴミ箱へ移動: `NSWorkspace.shared.recycle`）
- Finder で表示
- ターミナルで開く（そのディレクトリで新規ターミナルパネル）
- パスをコピー

### Drag & drop

- ツリー内 D&D: ファイル/フォルダを別フォルダに移動（`FileManager.default.moveItem`）
- ドロップ先のフォルダがハイライト
- 無効な移動（自分自身の中にフォルダを移動等）は拒否

## File Open Settings

- 設定キー: `file-explorer-open-action`
- 値:
  - `editor` — $EDITOR でターミナルパネルに開く（デフォルト）
  - `builtin` — Markdown パネル / テキストビューア
  - `system` — `open` コマンドでOSデフォルトアプリ

## Session Persistence

```swift
struct SessionFileExplorerPanelSnapshot: Codable, Sendable {
    var rootPath: String
    var expandedPaths: [String]    // 展開中のフォルダパス一覧
    var selectedPath: String?      // 選択中のファイルパス
    var showHiddenFiles: Bool
    var showIgnoredFiles: Bool
    var openAction: FileOpenAction // .editor / .builtin / .system
}
```

- `SessionPanelSnapshot` に `var fileExplorer: SessionFileExplorerPanelSnapshot?` を追加

## Integration Points

- **タブアイコン:** `folder.fill` (SF Symbol)
- **タブタイトル:** ルートディレクトリ名（例: "cmux"）
- **コマンドパレット:** "File Explorer" / "ファイルエクスプローラー" で検索可能
- **キーボードショートカット:** Cmd+Shift+E で新規ファイルエクスプローラーを開く
- **ソケットコマンド:** `panel.new_file_explorer` でCLIからも開ける

## Error Handling

- ルートパスが存在しない → ツールバーにエラー表示 + パス再選択を促す
- パーミッションエラー → アクセス不可フォルダにロックアイコン表示
- Git リポジトリでない場合 → Git ステータス表示をスキップ（エラーにしない）
