# AI agents working on LP

Rules for any AI coding agent (Claude Code, subagents, Codex, Copilot and others) that reads or
changes this repository. This file is the contract. **New to the project? Read
[`CODEX.md`](CODEX.md) first** — the complete guide to how LP works (written for Codex, useful to
any agent). `CLAUDE.md` has the detailed working notes and pitfalls.

## 1. Know the project first

- LP is a native macOS app (Swift 6.4, SwiftUI + AppKit, TextKit 1, Xcode 27) for macOS 15 and
  later, with a WidgetKit extension. Read `CODEX.md`, then `docs/ARCHITECTURE.md` before touching
  code and `docs/DESIGN_SYSTEM.md` before touching UI.
- The user's notes are the product. **Never risk their files**: no writes to a vault except
  through the app's own save paths, no "cleanup" of user folders, and every format change needs a
  round-trip test.

## 2. The non-negotiable workflow

The owner's two standing rules (full text in `CLAUDE.md`):

- **No release without the owner's confirmation.** Every change goes on its own sub-branch.
  Merging into `main` and releasing a new version happen only after the owner says yes to that
  release — and always through `Scripts/deploy.sh`, which backs up the current release first so it
  can be rolled back.
- **Every session updates the documentation** — `CHANGELOG.md`, `README.md`, the user guide PDF,
  `CLAUDE.md`, `AGENTS.md`, `CODEX.md` and `docs/` — to match what happened in it.

Step by step:

1. **Branch.** Never commit to `main` directly. Use `feature/<topic>`, `fix/<topic>` or `docs/<topic>`.
2. **Change in small, coherent steps.** Match the surrounding code's style, naming and comment
   density.
3. **Verify everything you change:**
   - `Scripts/test.sh` — every suite at 0 failed. New parser/serializer/model logic needs tests.
   - `Scripts/build.sh` — the sandboxed build succeeds with no new warnings.
   - **UI changes:** `Scripts/build.sh harness` + `Scripts/snapshot.sh`, then *look* at the PNGs
     (light, dark, narrow). Describe what you saw; do not claim a visual result you did not view.
     Widgets: `Scripts/render-widgets.sh` (Xcode cannot preview macOS widgets).
   - **Anything that runs on older systems:** the deployment target is macOS 15 — newer APIs go
     through `#available` helpers (`Design/Compatibility.swift`).
4. **Commit and push the branch** so the work is backed up on GitHub.
5. **Update the documents** (see the table in `CLAUDE.md`), including a `CHANGELOG.md` entry.
6. **Ask before releasing.** Tell the owner what is ready and which version it would be. Only
   after they confirm: merge into `main`, move the Unreleased lines of `CHANGELOG.md` under the new
   version (they become the release notes) and run `Scripts/deploy.sh <version> --confirmed`. It
   publishes a backup of the version being replaced before releasing the new one. Never release
   by hand.
7. **Roll back with `Scripts/rollback.sh`**, which creates a branch or downloads an app — it never
   rewrites `main`.

## 3. What agents must not do

- Merge into `main`, tag, or publish a release without the owner's confirmation of that release.
- Force-push, rewrite published history, delete tags, delete GitHub Releases, or delete branches
  others may use — unless the owner explicitly asks for it.
- Commit secrets: OAuth tokens, GitHub tokens, client secrets, personal data. Tokens belong in the
  Keychain; client IDs are entered by the user in Settings.
- Send the user's notes or personal data to any service the user did not ask for.
- Take outward-facing actions (publishing, sharing, emailing, creating repositories, opening PRs
  on other projects) without the user's go-ahead.
- Approve tool or plugin installs on the user's behalf.
- Mark work done when tests fail or a step was skipped — report it plainly instead.

## 4. Definition of done

- [ ] Tests green, sandboxed build green, no new warnings
- [ ] UI reviewed in light and dark and a narrow window (design checklist in `docs/DESIGN_SYSTEM.md`)
- [ ] Accessibility: contrast ≥ 4.5:1, labels on icon-only controls, keyboard path, Reduce Motion
- [ ] Docs updated for this session: `CHANGELOG.md`, `README.md`, the user guide PDF (if anything
      visible changed), requirement status in `docs/PRODUCT_REQUIREMENTS.md`, architecture and
      design notes, `CODEX.md`, `CLAUDE.md` "Where things stand" and pitfalls
- [ ] Committed on a branch and pushed; merged and released only after the owner confirmed,
      through `Scripts/deploy.sh`

## 5. Useful tools in this environment

| Tool | Use it for |
|---|---|
| Xcode plugin (MCP: `XcodeOpenWorkspace`, `BuildProject`, `GetBuildLog`, `UpdateTargetBuildSetting`, `AddEntitlement`, `AddInfoPlist`, `XcodeNewTarget`, `DocumentationSearch`) | Builds, target build settings, entitlements, Info.plist keys, new targets, Apple docs. Project-level settings (versions) are edited in `project.xcproj` by hand; the shared scheme is `Local Productivity` |
| `swiftui-whats-new-27` skill | Any SDK 27 SwiftUI API (`reorderable`, `@State` macro, toolbars) |
| `ui-ux-pro-max` skill | Design decisions and reviews |
| `dataviz` skill | Any chart, stat tile or chart colour — validate palettes with its script |
| `gh` CLI | Repository, releases (already authenticated) |
| `Scripts/signing-team.sh` | Find a signing team for `LP_TEAM_ID` (widgets need one to show data) |
| `Scripts/make-user-guide.sh` | Rebuild the user guide PDF after editing `docs/user-guide/guide.html` — then look at every page |

## 6. Communicating with the user

Explain results in plain language: what changed, where it is, how it was verified, and anything
the user needs to do. Keep jargon out of user-facing messages.
