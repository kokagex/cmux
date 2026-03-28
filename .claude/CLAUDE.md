# cmux

macOS terminal multiplexer. Swift/AppKit + Ghostty.

## Critical rules

<!-- These 5 rules are duplicated in .claude/rules/ for Claude Code auto-loading.
     They are kept here because AGENTS.md (Codex) symlinks to this file and
     cannot read .claude/rules/. Do not remove. -->

1. Debugビルドはユーザー指示なしに実行しない
2. untagged `cmux DEV.app` を起動しない — tagged build のみ使う
3. テストはCI実行のみ、ローカル禁止
4. user-facing文字列は必ずローカライズ（`String(localized:defaultValue:)`）
5. ビルド後は `file://` URLリンクだけ出力、余計なテキスト不要

## Setup

```bash
./scripts/setup.sh
```

## Build

```bash
./scripts/reload.sh --tag <tag>           # Debug (tagged, build only)
./scripts/reload.sh --tag <tag> --launch  # Debug (tagged, build + launch)
./scripts/reloadp.sh                      # Release (kill + launch)
./scripts/reloads.sh                      # Staging
```

## Release

```bash
./scripts/bump-version.sh          # bump minor
./scripts/bump-version.sh patch    # bump patch
./scripts/bump-version.sh 1.0.0    # set specific version
git tag vX.Y.Z
git push origin vX.Y.Z
```

- Requires GitHub secrets for signing and notarization.
- Release asset: `cmux-macos.dmg` attached to the tag.
- Use `/release` command for the full workflow.

## Ghostty submodule

```bash
cd ghostty
git checkout -b <branch>
# make changes, commit, push to manaflow fork
git push manaflow <branch>
```

Keep `docs/ghostty-fork.md` up to date with fork changes.
