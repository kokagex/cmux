# Policies

## Testing policy

**Never run tests locally.** All tests (E2E, UI, python socket tests) run via GitHub Actions or on the VM.

- **E2E / UI tests:** trigger via `gh workflow run test-e2e.yml`
- **Unit tests:** `xcodebuild -scheme cmux-unit` is safe (no app launch), but prefer CI
- **Python socket tests (tests_v2/):** connect to a running cmux instance's socket. Never launch an untagged `cmux DEV.app`. If testing locally, use a tagged build's socket with `CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock`

## Test quality policy

- Tests must verify observable runtime behavior, not source code text or AST patterns.
- Do not read checked-in metadata (Info.plist, project.pbxproj) just to assert a key exists.
- For metadata changes, verify the built app bundle or runtime behavior.
- If no meaningful behavioral test is practical, skip the fake test and state that explicitly.

## Regression test commit policy

Two-commit structure:
1. **Commit 1:** Add the failing test only (no fix). CI should go red.
2. **Commit 2:** Add the fix. CI should go green.

## Localization

**All user-facing strings must be localized.** Use `String(localized: "key.name", defaultValue: "English text")` for every UI string. Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages (English and Japanese). Never use bare string literals in SwiftUI `Text()`, `Button()`, alert titles, etc.

## Socket command threading policy

- Do not use `DispatchQueue.main.sync` for high-frequency telemetry commands (`report_*`, `ports_kick`).
- Telemetry hot paths: parse/validate/dedupe off-main, schedule minimal UI mutation with `.async` only when needed.
- Commands that directly manipulate AppKit/Ghostty UI state are allowed on main actor.
- New socket commands default to off-main; require explicit reason in comments for main-thread.

## Socket focus policy

- Socket/CLI commands must not steal macOS app focus.
- Only explicit focus-intent commands may mutate in-app focus/selection (`window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`, browser focus commands).
- Non-focus commands preserve current user focus context.

## Submodule safety

When modifying a submodule (ghostty, vendor/bonsplit, etc.), always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD. Verify: `cd <submodule> && git merge-base --is-ancestor HEAD origin/main`.

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the `manaflow-ai/ghostty` fork. Keep `docs/ghostty-fork.md` up to date.

```bash
cd ghostty
git checkout -b <branch>
git add <files> && git commit -m "..."
git push manaflow <branch>
```

Fork sync:
```bash
cd ghostty && git fetch origin && git checkout main && git merge origin/main && git push manaflow main
cd .. && git add ghostty && git commit -m "Update ghostty submodule"
```
