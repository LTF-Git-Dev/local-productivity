# LP (Local Productivity) — working notes for Claude

LP is a native macOS app (SwiftUI + AppKit/TextKit 1) that turns any folder of Markdown files
into a calm, Notion-style workspace: a WYSIWYG editor, a calendar synced with Apple, Google and
Microsoft calendars, and Trello-style boards with progress tracking and sharing. The files stay
plain Markdown, compatible with Obsidian.

Read these before changing anything substantial:

| Document | What it covers |
|---|---|
| `docs/PRODUCT_REQUIREMENTS.md` | What LP is for, every requirement and its status, roadmap |
| `docs/ARCHITECTURE.md` | Modules, data flow, file formats, sync, security, testing |
| `docs/DESIGN_SYSTEM.md` | Tokens (measured contrast), type, spacing, motion, components, review checklist |
| `AGENTS.md` | Rules for any AI agent working on this repository |
| `CODEX.md` | The complete guide to the project (written for Codex; a good tour for anyone) |
| `README.md` | User-facing overview, shortcuts, Markdown support |

## Where things stand

| | |
|---|---|
| App name | **LP** (product and window); bundle ID `LTF.Local-Productivity` (unchanged so settings carry over); Xcode project/target still named "Local Productivity" |
| Released | **v1.0.0** (2026-11-18) — the first release: everything to date (notes, calendar sync, boards with tracking and sharing, reminders, widgets, text controls, macOS 15–27) and the user guide; a GitHub Release with the app zip and the guide. The earlier test releases 1.0.0 and 1.1.0 were withdrawn that day (see `CHANGELOG.md`); their apps are kept in `../Release backups/withdrawn test builds/`. |
| Next | 1.1 — see the roadmap in `docs/PRODUCT_REQUIREMENTS.md` (backlinks, links updated on rename, week view) |
| Platform | macOS 15 and later (deployment target 15.0); newer APIs through `Design/Compatibility.swift` |
| Targets | `Local Productivity` (LP.app) and `LPWidgetsExtension` (embedded); shared scheme `Local Productivity`; versions at project level |
| Branches | `main` = what is released; do new work on `feature/…` / `fix/…` branches |
| Repository | `github.com/LTF-Git-Dev/local-productivity` (private), remote `origin`, authenticated `gh` |
| Tests | `markdown` 355 · `calendar` 63 · `safety` 54 · `widgets` 18 · `reminders` 54 · `boards` 137 (681 in all) — all must stay at 0 failed |
| Tooling | Xcode 27.2; `xcode-select` points at Xcode; the **Xcode plugin** (`xcode@claude-plugins-official`) is installed and approved |

Known limits worth remembering: tables are edited in a sheet; renaming a page does not update
`[[links]]`; Google/Microsoft sync needs the user's own OAuth client ID (Settings → Calendars);
with ad-hoc signing, macOS may ask again for the workspace folder or Keychain access after a
rebuild, and widgets cannot get data (they need a team — `LP_TEAM_ID`, `Scripts/signing-team.sh`);
notification delivery needs the user's permission, which the harness never requests.

## ⚠️ The owner's rules — never skip them

Set by the owner (2026-11-18). They override anything else in this repository.

**1. No release without the owner's confirmation.**

1. **Every change goes on its own sub-branch** off `main` — `feature/…`, `fix/…`, `docs/…` — never
   on `main`. Commit in coherent steps and push the branch to `origin`, so work in progress is
   backed up too.
2. When the work is done and tested, **ask the owner** whether to release it, naming the version
   ("Ready to release v1.1.0 — shall I merge it into main and release it?").
3. **Only after the owner confirms:** merge the branch into `main`, set `MARKETING_VERSION`
   (project level), and release with `Scripts/deploy.sh <version> --confirmed`. Without that
   confirmation nothing is merged into `main`, tagged or published. (`deploy.sh` enforces it: it
   asks for the version to be typed, or needs `--confirmed`.)
4. **Never lose the way back.** Every release is a tag plus a GitHub Release with the app zip.
   `deploy.sh` refuses to publish until the version being replaced is backed up that way.
   Try `Scripts/deploy.sh <version> --dry-run` first.
5. **To roll back:** `Scripts/rollback.sh` lists releases; `Scripts/rollback.sh 1.0.0` downloads
   that app; `Scripts/rollback.sh 1.0.0 --source` puts that code on a `rollback/to-v1.0.0` branch
   (one commit on top of `main`, history kept) to merge and redeploy — after the owner confirms.
6. Never force-push, rewrite published history, delete tags or delete releases unless the owner
   asks for exactly that. (They did once, on 2026-11-18: the test releases 1.0.0 and 1.1.0 were
   removed and the app started again at 1.0.0.)

**2. Every session updates the documentation.** Before a session ends, bring every document up to
date with what happened in it, on the session's branch:

| File | Update with |
|---|---|
| `CHANGELOG.md` | A dated entry under **Unreleased**: what changed, the branch, whether it was released |
| `README.md` | Features, shortcuts, setup steps, known limits |
| `docs/LP User Guide.pdf` | Anything a user sees: edit `docs/user-guide/guide.html` (and screenshots), then `Scripts/make-user-guide.sh` |
| `CLAUDE.md` | "Where things stand", commands, harness steps, pitfalls learned |
| `AGENTS.md` | Rules, if they changed |
| `CODEX.md` | Repository map, architecture, recipes, pitfalls |
| `docs/PRODUCT_REQUIREMENTS.md` | Requirement status and roadmap |
| `docs/ARCHITECTURE.md` · `docs/DESIGN_SYSTEM.md` | How it works · how it looks |

If a document has nothing new to say, leave it — but check each one.

Commits end with:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

## Build, test, look

```sh
Scripts/test.sh               # all suites (or: markdown | calendar | safety | widgets | reminders | boards); 0 failed
Scripts/build.sh              # sandboxed Debug build (what Xcode produces)
Scripts/build.sh harness      # unsandboxed Debug build for snapshots
Scripts/snapshot.sh <name> "<step> ;; <step> ;; …"   # drive the real app, save PNGs
Scripts/make-demo-vault.sh    # rebuild the sample workspace (.build/demo-vault)
Scripts/make-stress-vault.sh  # 3,000-note workspace for speed work (use with the perf-* steps)
Scripts/render-widgets.sh     # draw the widgets light/dark (Xcode can't preview macOS widgets)
Scripts/signing-team.sh       # signing teams for LP_TEAM_ID (builds and deploys sign with it)
Scripts/make-user-guide.sh    # rebuild docs/LP User Guide.pdf from docs/user-guide/ — then look at every page
Scripts/deploy.sh <version> [--dry-run | --confirmed]   # release (owner-confirmed only), backing up the current version first
Scripts/rollback.sh [<version> [--source]]
```

The Xcode plugin's tools also work (open the project with `XcodeOpenWorkspace`, then
`BuildProject`, `GetBuildLog`, `RunProject`, `UpdateTargetBuildSetting`, `AddEntitlement`,
`AddInfoPlist`, `DocumentationSearch`). Use them for build settings, entitlements and Info.plist
keys instead of editing `project.xcproj` by hand.

**Always look at the result.** After any change to the interface or editing behaviour, build the
harness, run a scenario and read the PNGs in `.build/shots/<name>/` — light and dark, and a narrow
window. Useful variables: `LP_APPEARANCE=light|dark`, `LP_SNAPSHOT_SIZE=1280x800`,
`LP_SNAPSHOT_ACTIVATE=1` (active window; needed for `keys:` and real events), `LP_WORKSPACE=`
(empty = welcome screen).

Harness steps worth knowing (full list in `Debug/SnapshotHarness.swift`):

- Navigation: `open:<path>` (pages and boards), `route:home|calendar|boards|folder=<path>`, `new:`,
  `palette:<query>`, `settings:<general|editor|notifications|calendars|sharing>`, `url:<link>`
- Editor: `type:`, `keys:` (real key events — the only way to test undo grouping), `shortcut:cmd =`
  (key events with modifiers, through the menus), `key:`, `find:`, `select:`, `format:`, `turn:`,
  `block:`, `dump`, `cat`, `layout`, `setting:size=17|spacing=relaxed|width=wide|font=…|interface=small`
- Calendar: `demo-calendar` (in-memory account), `select-day:<offset>`, `event-editor:new|<title>`,
  `event-create:<title>@<dayOffset>@<hour>`, `event-update:`, `event-delete:`, `events:<filter>`
- Boards: `new-board:<folder>` (sheet), `create-board:<name>|<template>|<folder>`,
  `board-add:<list>=<text>`, `board-move:<card>=<list>[@<before card>]`,
  `board-card:<title>`, `board-progress[:off]`, `board-undo`, `board-log:<n>`,
  `mouse-drag:x1,y1>x2,y2` (real mouse events through the app's queue)
- Reminders: `reminders` (prints the plan), `reminder:<open|done|hour|tomorrow>=<title>`,
  `reminder-permission:<allowed|denied|ask>`; widgets data: `LP_WIDGET_SNAPSHOT=<path>`
- Speed: `perf-load`, `perf-open:`, `perf-type:`, `perf-save`, `perf-search:`, `perf-phases`, `perf-memory`
- Files: `write:<path>=<text>` changes a file behind the app's back; `state` prints the route

## Things that are easy to get wrong

**Editor**
- Never restyle text in `willProcessEditing` (AppKit moves the caret); style in
  `didProcessEditing` (`StorageNormalizer`), then `fixFontAttribute(in:)`.
- The storage always ends with a newline; one paragraph is one block; line breaks inside a block
  are U+2028.
- All edits go through `replace` / `setBlock` / `grouped` in `EditorTextView+Editing.swift`.
- Block spacing is set in `EditorTextContainer` against a fixed target (TextKit re-asks for tall
  lines; adding to the proposal doubles the gap).
- Presentation-only attributes (`.lpDueDate`) must be in `lpDerivedKeys` and never affect saving.

**Concurrency and SwiftUI (SDK 27)**
- Default actor isolation is MainActor. Pure logic and TextKit subclasses are `nonisolated`;
  `Transferable` conformances on model types go in a `nonisolated extension`.
- `@State` is a macro in SDK 27: set initial values in `init` with `_x = State(initialValue:)` and
  do not also give the property a default (see the Xcode plugin's `swiftui-whats-new-27` skill).
- A sheet that edits something must initialise its fields in `init`, not `onAppear` — pickers
  clamp values against placeholders otherwise (this broke event end times once).
- Pass the window's `undoManager` into sheets; a sheet's own undo manager disappears with it.

**Boards**
- Boards are Obsidian Kanban files; keep the plugin's exact layout (two blank lines after each
  list, `**Complete**`, `%% kanban:settings %%` kept verbatim). `BoardTests` guards this.
- Card IDs are Obsidian block IDs (`^c…`); `adoptIDs` maps cards without IDs across reloads.
- Never write to the user's notes when opening a board; the log in `.lp/boards/` is written only
  when something new is recorded.
- Mutations must not read and write the same array element in one access (Swift exclusivity) —
  copy flags into locals first.
- Scripted harness steps produce no events, so undo groups don't close by themselves; board steps
  post an event (`endEvent(in:)`) — real use is unaffected.

**Calendar**
- All-day events are floating: local midnight to the midnight after the last day; EventKit's
  inclusive end is converted. Timed events are absolute instants.
- Only the provider mappings are Foundation-only and tested; keep networking out of them.
- Google needs an "iOS" OAuth client; Microsoft needs the "iOS / macOS" platform with redirect
  `msauth.<bundle id>://auth`. No client secrets anywhere.

**Type, settings and menus**
- Interface fonts use `Font.lp(size:)` (follows the interface size); the editor's type comes only
  from `EditorTheme` (text size, line spacing, typeface). Don't add `.system(size:)` to screens.
- Menu `Commands` are not reliably redrawn when observed values change: no `.disabled(...)` on
  commands for fast-changing state (⌘0 stayed disabled once).
- Synthetic key events must put Shift into `charactersIgnoringModifiers`, as real ones do.

**Reminders and widgets**
- Pure planning lives in `ReminderPlanner`/`WidgetSnapshot` (tested); system calls in
  `ReminderCenter`/`WidgetPublisher`. The notification delegate is `nonisolated` and hops to the
  main actor with plain values. Snapshots (`AppModel(defaults: nil)`) never schedule or ask.
- Widget data needs a team-signed build; `WidgetStore` checks the code signature and leaves the
  group container alone otherwise (no consent prompts).
- `ImageRenderer` can't draw `Link`/`ProgressView`; widgets use `WidgetLink` and `ProgressBar`.

**Speed**
- Strings from the editor are bridged `NSString`s: call `makeContiguousUTF8()` before walking them
  per character (saving a 2 MB note went from 9.5 s to 0.5 s with this and the paragraph cache).
- Profile with `xcrun xctrace record --attach <pid>` on a harness run against
  `$CLAUDE_JOB_DIR/tmp/stress-vault` (launching through xctrace hits TCC in `~/Documents`).

**Workspace and files**
- Hidden folders (`.lp`, `.obsidian`, `.git`) are skipped by the scanner and the watcher.
- Two `ForEach` rows with the same id in one lazy stack collide; give repeated items distinct ids.
- The Markdown engine stays Foundation-only; add a test for every parser/serializer change. The
  bar is byte-for-byte round-trips of untouched text (the realistic-notes fuzz checks it).
- Paths from note content or links go through `PathSafety`; links through `LinkSafety`.

**Docs and releases**
- The user guide is printed by WebKit, which ignores `break-after: avoid` and misplaces floats
  that cross a page: a script in `guide.html` keeps headings with what follows, and figures beside
  text use `.aside` blocks. After any change, render the pages to PNGs and look at all of them.
- PDFKit's writer (macOS 27) drops bookmarks and saves link targets without their page;
  `make-user-guide.swift` writes the final PDF with Core Graphics instead.
- The formatting-bar screenshot needs `focus` before `select:` and a wait, or the bar isn't up.
- Release notes are the version's `## <version>` entry in `CHANGELOG.md` — write it before releasing.

## Design rules

Follow `docs/DESIGN_SYSTEM.md`. In short: use the tokens (`lpInk…`, `lpCanvas`, `lpHairline`,
status tokens, `Metrics`, `Animation.lpQuick/lpSmooth`), never literal colours; text must clear
4.5:1 (the tokens do — measure anything new with the dataviz validator); status is never colour
alone; icon-only controls need `.help` and `.accessibilityLabel`; targets ≥ 24pt; respect Reduce
Motion. For charts, load the `dataviz` skill first; for UI decisions, the `ui-ux-pro-max` skill.
Visual quality is a requirement: check light, dark and narrow before calling UI work done.
