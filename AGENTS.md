# AGENTS.md

DiskManager: a native macOS app (SwiftUI, SPM, macOS 14+) that compares, syncs and cleans up two storage spaces. User-facing behaviour is documented in [README.md](README.md); read it before changing sync or cleanup logic.

## Commands

```bash
swift build                                        # debug build
swift run DiskManager                              # run without packaging (also: make run)
swift test                                         # unit tests (also: make test)
DM_SCALE_TEST=1 swift test --filter ScaleSmokeTests  # 80k-file scan memory smoke test; slow, skipped by default
make app                                           # release bundle at build/DiskManager.app (scripts/build-app.sh)
```

- Needs full Xcode, not just the Command Line Tools: with CLT selected, `swift build` fails (`SwiftUIMacros` plugin not found) and `swift test` fails (no `XCTest`). Check `xcode-select -p`; to avoid changing the system setting, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `make app` signs with an installed Apple Development / Developer ID identity (override with `CODESIGN_IDENTITY=`). Full Disk Access is tied to the signature, so an ad-hoc build loses the grant on every rebuild.
- Version lives in `scripts/Info.plist`. Releases are `DiskManager-<version>.zip` on GitHub Releases.

## Layout

- `Sources/DiskManagerCore/`: UI-independent logic (scan, diff, sync, junk scan, export). Knows nothing about A/B; keep it that way.
- `Sources/DiskManager/`: SwiftUI app, AI chat panel, Keychain storage.
- `docs/`: the website (`docs/index.html` + `docs/assets/`), not developer docs.

## Workflow and deploy

- Single `main` branch; commit and push directly to `main`.
- The website is deployed by Vercel's Git integration from `main`, with `docs/` as the project root, at https://disk-manager.derekdylu.com. A push to `main` is the deploy; verify via the Vercel commit status.
- GitHub Pages is intentionally off. Never link to `github.io` and don't add `docs/.nojekyll`.

## Conventions

- Terminology: a storage space (儲存空間) can be any folder; don't write it as "external drive". A is the target space (the baseline, never modified, accent-highlighted); B is the working space that gets changed. The Swap button reverses them, so don't add mirrored modes (B→A, A−B). Modes: mirror, difference, union (in union neither side is highlighted).
- Language: code comments, README, docs and script output are English. UI strings are bilingual inline pairs `tr("中文", "English")` (`Sources/DiskManager/L10n.swift`); never translate or drop either literal.
- AI chat: bring-your-own key for Anthropic or OpenAI, stored only in the Keychain (`KeychainStore`) and sent only to that provider's API. No third-party dependencies.

## Safety boundaries

- Data safety first. Scanning and comparing are read-only. Every destructive action needs a preview and a confirmation.
- Never delete outright by default: extra or replaced files go to `_DiskManager_Archive/<timestamp>/` (`SyncEngine.archiveRootName`); cleanup defaults to the Trash.
- Changing A or B must invalidate the cached scan and the on-screen plan (`AppState.spaceDidChange`), so an old plan can't run against new folders.
- Overwrites are atomic (temp file + rename).

## Gotchas

- Every file enumeration / read / copy loop on a background thread must wrap each item in `autoreleasepool`, or memory grows without bound on large drives.
- Sync compares size + mtime with a 2-second tolerance (`Differ.mtimeTolerance`, for exFAT). No checksums.
- Foundation directory enumeration hides AppleDouble (`._`) files; the junk scan finds them with a separate POSIX `readdir` pass.
- Swift `String ==` uses Unicode canonical equivalence, so NFC and NFD names compare equal. Paths are keyed by `ScanResult.normalizedKey` (NFC, plus case folding on case-insensitive volumes); compare `.utf8` when you need byte identity.
