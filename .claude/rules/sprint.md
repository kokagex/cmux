# Sprint Workflow

## harness/ directory

エージェント間通信用のファイル。スプリント契約と評価レポートで構成される。

```
harness/
├── current-sprint.md        # 現在のスプリント契約（gitignored）
├── specs/                   # フィーチャースペック（gitignored）
├── sprint-log/              # 過去のスプリント記録（git管理）
└── evaluation/              # 評価レポート（git管理）
    └── latest.md
```

- `current-sprint.md` と `specs/` はエフェメラル（.gitignore）
- `sprint-log/` と `evaluation/` は履歴として git 管理
- 並行作業時は `current-sprint-{tag}.md` で分離

## スキル使用ガイドライン

| タスク規模 | ワークフロー |
|---|---|
| 小（1時間以内、バグ修正等） | スキル不要。直接実装 |
| 中（数時間、1機能追加） | `/plan-sprint` → 実装 → `/evaluate-sprint`（任意） |
| 大（1日以上、複数ファイル） | `/plan-sprint` → `/execute-sprint` → `/evaluate-sprint` |

## ワークフロー

```
ユーザー: 「Xを実装して」
    │
    ▼
/plan-sprint → harness/current-sprint.md + harness/specs/{feature}.md
    │
    ▼
ユーザー確認 → OK
    │
    ▼
実装（新セッション推奨）→ コード変更
    │
    ▼
/evaluate-sprint（別セッション）→ harness/evaluation/latest.md → GO / NO-GO
    │
    ▼
GO → コミット / NO-GO → 修正ループ
```
