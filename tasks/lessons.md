# Lessons

## ビルド後のパス出力（2026-03-28）

reload.sh / reloadp.sh / xcodebuild 実行後は **必ず最初にディレクトリの絶対パスをプレーンテキストで出力** する。
**マークダウンリンクだけでは不十分。** `[cmux.app](file://...)` だと「cmux.app」としか表示されず、ビルド先ディレクトリがわからない。
リンクの **前に** 絶対パスを書く。例:

```
パス: /Users/kokage/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/cmux.app

[cmux.app](file:///Users/kokage/Library/.../cmux.app)
```

これを忘れるのは繰り返し指摘されている最重要の失敗パターン。
--launch を勝手に付けない。ユーザーが明示的に起動を指示した場合のみ。

## ユーザーの指示を1回で正確に聞く（2026-03-28）

- 「リリースビルド」→ `reloadp.sh`。Debug/devに勝手に切り替えない。
- 指示を却下されたら、却下理由を正確に理解してから次のアクションを取る。
- 同じ修正を2回言わせるのは最悪のパターン。1回目で確実に反映する。
- memoryに書いてあることは毎回確認して従う。
- リリースビルドのDerivedDataパスは `/Users/kokage/cmux/DerivedData`。デフォルトのXcode DerivedData（~/Library/Developer/Xcode/DerivedData）を使わない。
