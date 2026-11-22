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

The owner's standing rules (full text in `CLAUDE.md`):

- **No release without the owner's confirmation — and every version is a beta first.** Every
  change goes on its own sub-branch. A version is published first as a beta (a GitHub
  pre-release, from its branch) after the owner says yes to it; it becomes the official version —
  merged into `main`, marked Latest — only after the owner has tested the beta and confirmed it
  works. Always through `Scripts/deploy.sh`, which backs up the current release first so it can be
  rolled back. Full steps: `docs/RELEASING.md`.
- **The security checklist before any version is finalized** — `docs/SECURITY_CHECKLIST.md`: look
  into every point whose condition applies, fix what is found, record the result.
- **The repository stays private** until the owner says it can be public.
- **Every session updates the documentation** — `CHANGELOG.md`, `README.md`, the user guide PDF,
  `CLAUDE.md`, `AGENTS.md`, `CODEX.md` and `docs/` — to match what happened in it.
- **Codex reviews every finished task** — through Herdr, in the panel to the right of Claude —
  and everything is tested again before the owner is asked to release it.

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
6. **Get it reviewed.** The Codex agent in the right-hand Herdr panel reviews the code base (see
   §7). Check each finding, fix the real ones with tests, have Codex look at the fixes, and test
   everything again.
7. **Run the security checklist** (`docs/SECURITY_CHECKLIST.md`) and add the version's result to
   its record, with the output of `LP_TEST_VERBOSE=1 Scripts/test.sh ownership`.
8. **Ask before publishing a beta.** Tell the owner what is ready and which beta it would be. Only
   after they confirm: set `MARKETING_VERSION`, move the Unreleased lines of `CHANGELOG.md` under
   the new version (they become the release notes), push, and run
   `Scripts/deploy.sh <x.y.z-beta.n> --confirmed` — a pre-release built from the branch.
9. **Make it official only when the owner confirms the beta works:** merge into `main`, then
   `Scripts/deploy.sh <x.y.z> --confirmed`. It publishes the newest beta's own app (refusing if
   that beta isn't properly published or the app's files changed since), and a backup of the
   version being replaced first. Never release by hand.
10. **Roll back with `Scripts/rollback.sh`**, which creates a branch or downloads an app — it never
    rewrites `main`.

## 3. What agents must not do

- Add analytics, telemetry, crash reporting, advertising, third-party SDKs or any server of ours —
  LP is local-first and private by design (see `PRIVACY.md`).
- Ask a connected service for a broader permission, or fetch, store or share more data, than a
  feature needs — and never without updating `PRIVACY.md` and `docs/CONNECTED_ACCOUNTS.md` in the
  same change (the calendar tests pin the permissions).
- Put the owner's personal details (name, email) into files, commits or requests to outside
  services; the copyright holder is the GitHub account, LTF-Git-Dev.
- Merge into `main`, tag, or publish a release — beta or official — without the owner's
  confirmation of that step. A yes to a beta is not a yes to the official release.
- Make the repository public, or change its visibility, without the owner's explicit say-so.
- Publish an app whose signature shows a personal email address, or that contains a token or key
  (`deploy.sh` checks both).
- Force-push, rewrite published history, delete tags, delete GitHub Releases, or delete branches
  others may use — unless the owner explicitly asks for it.
- Read, print, move or export the release signing key (Keychain item "LP release signing key"),
  or weaken what the updater checks (signature, checksum, bundle ID, version, code signature).
- Commit secrets: OAuth tokens, GitHub tokens, client secrets, personal data. Tokens belong in the
  Keychain. Client IDs are public identifiers — LP's own live in `BuiltInRegistration.swift`, a
  person's own in Settings — and there is never a client secret.
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
- [ ] Reviewed by Codex; every finding fixed or explained; everything tested again afterwards
- [ ] Security checklist run for the version and recorded in `docs/SECURITY_CHECKLIST.md`
- [ ] Committed on a branch and pushed; a beta published only after the owner's yes; merged and
      released as official only after the owner confirmed the beta — through `Scripts/deploy.sh`

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
| `Scripts/make-site.py`, `Scripts/make-site-shots.sh` | LP's website: pages from the policies, screenshots from the harness. Look at it over `http://127.0.0.1` in light, dark and phone widths; publishing it needs the owner's yes |

## 6. Communicating with the user

Explain results in plain language: what changed, where it is, how it was verified, and anything
the user needs to do. Keep jargon out of user-facing messages.

## 7. When you are the reviewer

Codex reviews Claude's work before every release (Claude asks through Herdr). As the reviewer:

- **Read; don't change.** Don't edit files, commit, push or change git state — Claude is working
  in the same checkout. Reading files, `git log`/`git diff` and searching are fine.
- **Start with the branch's changes** (`git diff main...HEAD`), then follow them into the code they
  touch. Hold the work to this file, `CODEX.md` and `CLAUDE.md`: the user's files must never be at
  risk; the security model (paths, links, tokens) and the security checklist
  (`docs/SECURITY_CHECKLIST.md`); the concurrency rules; tests for every parser, serializer and
  model change; the design system for UI; the documents kept current.
- **Report only what is actionable**, most severe first. For each finding: the file and line, what
  goes wrong (a concrete input or situation and its result), how sure you are, and a suggested
  fix. Mark style or taste points as minor, or leave them out.
- **Say so plainly when you find nothing actionable.** When Claude sends fixes, check each one
  against the finding it answers.
