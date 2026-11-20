# Lily — Claude Rules

Native macOS browser. Pure Swift + SwiftUI (AppKit/WebKit only where unavoidable). Modules: `core/`, `injections/`, `agent-bridge/`, `ui/`. Part of the Lily-browser org: this repo is the macOS shell; platform-neutral code lives in **LilyKit** (separate repo, shared with Lily-ios). No Electron/web wrappers. Priorities: user delight, low CPU/RAM/energy (zero idle wake-ups), small binary.

## Token discipline (user is token-constrained)
- Work inline. Spawn **at most one** `builder` per task, and only for large multi-file work. Don't spawn `qa-tester`/`sec-auditor` by default: run the gates yourself. Use `sec-auditor` only for new network/IPC/storage/entitlement surface, or when asked.
- Read only the files you need (Grep first, then a ranged Read). Don't read README.md (49 KB) or the docs/ files unless the task needs them.
- No optional extras, no unrequested refactors. Reports: a few lines, no change log restating the diff.
- Act on established facts; don't re-ask decisions the user already made.
- Context hygiene: after a PR is opened, or once a session gets long, end the reply with a one-line reminder: "`/compact` now (or `/clear` before an unrelated task)". Claude can't run these itself.

## Repos and LilyKit
- Code with no AppKit/SwiftUI that iOS could also use goes in `Lily-browser/LilyKit`, never here. Don't add iOS code to this repo.
- LilyKit is pinned in `core/Package.swift` (`exact:` tag, or `revision:` until a release exists). Change flow: PR in LilyKit → merge → tag → bump the pin here in the PR that needs it. Never commit `.package(path:)` (the lint rejects it).
- The kit's declarations are `public`; new kit API needs `public` (and a `public init` for structs). `LilyCore` re-exports the kit, so shell code uses its types unqualified.
- Kit tests run in the kit's CI; this repo's `swift test` covers only the shell. The kit's own `scripts/security-lint.sh` enforces the same code rules there.

## Code rules (most are enforced by `make lint` → `scripts/security-lint.sh`, which the pre-commit hook runs)
- Concurrency: `async/await`, `actor`, `@MainActor` only; `SWIFT_STRICT_CONCURRENCY = complete`.
- Logging: `os.Logger` only, with `privacy: .sensitive` on dynamic values. No `print`/`NSLog`.
- Secrets/cookies/session go in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never UserDefaults or files.
- `Process()`: absolute binary path + `arguments: [String]`, never a shell. XPC: validate the peer's code signature.
- WebKit: schema-validated JSON message handlers; no `eval`/string timers/`innerHTML` with dynamic input; no interpolated JS strings; CSP without `unsafe-inline`; `allowFileAccessFromFileURLs = false`.
- No unsafe pointers except AppKit signatures (mark with `// AppKit API signature`). UI errors are sanitized (no paths/traces).
- Scripts: `set -euo pipefail`, `export PATH="/usr/bin:/bin:/usr/sbin:/sbin"`, quote every expansion, `umask 077` + `mktemp -d`.
- Sandbox entitlements stay minimal (network.client only; user-selected files via security-scoped bookmarks). SPM deps pinned (`exact:`/`revision:`).
- Tabs (`core/tabs/`): metadata-first `struct TabItem`, web views only for the visible pool, hibernate after 30 min idle, lazy containers. Must handle 5,000+ tabs.
- Migration (`core/migration/`): runs in `MigrationActor`, SQLite opened `SQLITE_OPEN_READONLY`, URLs deduplicated.

## WebKit extension runtime: hard-won rules (macOS 15.4+, `WKWebExtensionController`)
Before touching extensions, read `docs/EXTENSIONS.md` → *Debugging an extension*.
- Popups: present `WKWebExtension.Action.popupPopover`. `action.setPopup("")` (1Password without an account) opens a tab by design.
- `webkit-extension://` pages in tabs need a web view built from `context.webViewConfiguration`. WebKit drops main-frame http(s) navigations from extension web views, so `Tab` cancels them and reloads in a regular web view (`Tab.swift` decidePolicy, `WebViewFactory.extensionConfiguration(for:)`).
- Keep `inactiveSchedulingPolicy = .none` (`ExtensionManager.configuration()`); `.suspend` kills the background mid-task. An idle MV3 background still unloads after ~30 s, and messages wake it.
- WebSocket in a service worker deadlocks WebKit. The worker shim bridges it via `dev.lily.websocket` (`ExtensionWebSockets.swift`). Suspect other sync-bridge APIs if a background goes silent.
- Native-messaging ports carry messages only after `connectUsing` returns. Lily sends `{type: "ready"}` first.
- Reserved in-process native-messaging names: `dev.lily.notifications`, `dev.lily.websocket`, `dev.lily.console` (all others are refused). Every extension with a background is granted `nativeMessaging`.
- The worker shim (`injections/extension-worker-compat.js`) is pinned per extension. After you change it, remove and re-add the extension.
- Shadowing `chrome.runtime` members doesn't work; wrapping event methods (`onMessage.addListener`) does.
- `context.errors` keeps about 25 entries, so measure observable state instead. Tests never use fixed sleeps: `await context.loadBackgroundContent()` and poll.

## Build, test, signing
- Gates before a PR: `make lint`, `cd core && swift test`, `make selftest`, plus `make perf` when touching `core/tabs/`, memory, or virtualization.
- User build: `CODESIGN_IDENTITY="<Apple Development identity>" make app` → `build/Lily.app` (team V56242Q2KF; find it with `security find-identity -v -p codesigning`). Ad-hoc builds lose Keychain data.
- Never run the signed app or its `--self-test` while the user is testing (shared container → freezes). `make selftest` is fine. The signed app's container isn't readable from the terminal, so use `/usr/bin/log`.
- 1Password desktop unlock and real native-messaging hosts are parked until Developer ID signing exists.

## Git
- On `main`, branch first (`feature/…`, `fix/…`). Conventional, atomic, signed commits. When the work is done, push and open the PR automatically without asking: `git push -u origin <branch>`, then `gh pr create` to `main`.
- Release (only when asked): `git tag -a vX.Y.Z`, `git push origin --tags`, `gh release create vX.Y.Z --generate-notes`.
