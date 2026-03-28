# Building Rules

## Debug builds

**Debugビルドはユーザーから指示された場合のみ実行すること。** コード変更後に自動でビルドしない。

Tagged reload script を使う:

```bash
./scripts/reload.sh --tag <your-branch-slug>           # build only
./scripts/reload.sh --tag <your-branch-slug> --launch   # build + launch
```

**Never run bare `xcodebuild` or `open` an untagged `cmux DEV.app`.** Untagged builds share the default debug socket and bundle ID with other agents, causing conflicts and stealing focus.

コンパイル確認だけなら tagged derivedDataPath:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<your-tag> build
```

## Release builds

```bash
./scripts/reloadp.sh    # Release app
./scripts/reloads.sh    # Staging app
./scripts/reload2.sh --tag <tag>  # Debug + Release
```

## Build path output

`reload.sh` prints an `App path:` line. Use it to build a `file://` URL:

1. Grab the path from the `App path:` line.
2. Prepend `file://` and URL-encode spaces as `%20`.
3. Output the `file://` URL as a markdown link. No decoration, no surrounding text — just the link.

**ビルド後は必ずアプリの `file://` URLリンクだけを出力すること。** いずれのビルド方法でも省略してはならない。余計なテキストや装飾は不要。

## Rebuilding dependencies

GhosttyKit.xcframework (always Release):
```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

cmuxd (always ReleaseFast):
```bash
cd cmuxd && zig build -Doptimize=ReleaseFast
```

## Parallel/isolated builds

Use `--tag` with a short descriptive name for parallel builds. This creates an isolated app with its own name, bundle ID, socket, and derived data path.

Before launching a new tagged run, clean up any older tags you started in this session (quit old tagged app + remove its `/tmp` socket/derived data).

## Debug event log

All debug events go to a unified log in DEBUG builds:

```bash
tail -f "$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || echo /tmp/cmux-debug.log)"
```

- Tagged: `/tmp/cmux-debug-<tag>.log`
- `reload.sh` writes path to `/tmp/cmux-last-debug-log-path` and CLI to `/tmp/cmux-last-cli-path`
- Implementation: `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`
- `dlog("message")` — all call sites must be wrapped in `#if DEBUG` / `#endif`
- 500-entry ring buffer; `DebugEventLog.shared.dump()` writes full buffer
