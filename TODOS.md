# TODOS

## CI Enforceable Guardrails
- **What:** pre-commit hookまたはCIステップでルール遵守を自動チェック（untagged build検出、未ローカライズ文字列検出等）
- **Why:** ドキュメントベースのルールはエージェントが無視する可能性がある。コードで強制すれば確実
- **Pros:** ルール遵守が機械的に保証される。エージェントの「読み忘れ」が問題にならなくなる
- **Cons:** hook/CI構築コスト。false positive対応が必要。一部ルールは機械的チェック不可能
- **Context:** Codexの外部レビュー（2026-03-28 /plan-eng-review）で指摘。ハーネス再構築（.claude/rules/ + harness/）の効果を2週間測定した後、ルール遵守率が十分改善しなかった場合の次の手段として検討。
- **Depends on:** ハーネス再構築の完了と効果測定
