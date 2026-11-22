# CODEX.md — understanding LP from the ground up

This is the complete guide to this repository for OpenAI Codex (and any other coding agent).
Read it once, end to end, before changing anything. The rules you must follow are in
[`AGENTS.md`](AGENTS.md); this file explains the project so those rules make sense.

Related documents: [`docs/PRODUCT_REQUIREMENTS.md`](docs/PRODUCT_REQUIREMENTS.md) (what and
why), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (how, in depth),
[`docs/DESIGN_SYSTEM.md`](docs/DESIGN_SYSTEM.md) (how it looks), [`CLAUDE.md`](CLAUDE.md)
(working notes and pitfalls), [`README.md`](README.md) (the user's view).

---

## 1. What LP is

**LP (Local Productivity)** is a native macOS app that turns any folder of Markdown files into a
calm, Notion-style workspace:

- **Notes** — a WYSIWYG editor that never shows Markdown syntax while you write, but saves plain
  CommonMark/Obsidian Markdown. Untouched text round-trips byte for byte.
- **Calendar** — month view with daily notes and due tasks, two-way sync with Apple Calendar
  (EventKit), Google Calendar and Microsoft Outlook.
- **Boards** — Trello-style boards stored as Obsidian Kanban Markdown files, with progress
  tracking, an activity history, sharing as a live read-only page, and an overview of every board.
- **Reminders** — local notifications for due tasks and cards, upcoming events and a morning summary.
- **Widgets** — "Today" and "Board" widgets for the desktop and Notification Center.

The user's folder is the source of truth. LP never locks data in, never writes a file the user
did not change, and stays compatible with Obsidian. **The single most important rule: never risk
the user's files.**

## 2. Quick facts

| | |
|---|---|
| Platform | macOS **15 Sequoia or later** (also 26 Tahoe, 27); Apple silicon and Intel |
| Toolchain | Xcode 27.2, Swift 6.4 in **Swift 5 language mode**, default actor isolation **MainActor** |
| UI | SwiftUI for screens; AppKit/TextKit 1 for the editor (`NSTextView`) |
| Project | `Local Productivity.xcodeproj` — Xcode 27 `project.xcproj` (JSON) with synchronized folders; shared scheme `Local Productivity` |
| Targets | `Local Productivity` → **LP.app** (bundle ID `LTF.Local-Productivity`); `LPWidgetsExtension` → widget extension (`LTF.Local-Productivity.Widgets`) |
| Versions | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` at **project level** (both targets share them) |
| Signing | Ad hoc ("Sign to Run Locally") unless `LP_TEAM_ID` is set; sandboxed, hardened runtime, no `get-task-allow` in Release |
| Repository | `github.com/LTF-Git-Dev/local-productivity` — public since 2026-11-23 with a fresh history (the earlier private history is the private `local-productivity-archive`; never push it here); remote `origin`, `gh` authenticated |
| Branches | `main` = the official release; work on `feature/…` or `fix/…` |
| Releases | GitHub Releases with the app zip and the user guide, via `Scripts/deploy.sh` only: **a beta first** (a pre-release from the branch, after the owner's yes), **official** (from `main`, marked Latest) only once the owner confirmed the beta — see `docs/RELEASING.md`. First release **1.0.0** (2026-11-18); notes come from `CHANGELOG.md` |

## 3. Repository map

```
.
├── AGENTS.md                 rules for every AI agent (the contract)
├── CODEX.md                  this guide
├── CLAUDE.md                 working notes, pitfalls, build/test commands
├── CHANGELOG.md              what changed in each version (release notes come from it)
├── README.md                 the user-facing overview
├── docs/                     PRODUCT_REQUIREMENTS · ARCHITECTURE · DESIGN_SYSTEM · CONNECTED_ACCOUNTS
│                             · RELEASING (beta first) · SECURITY_CHECKLIST (the owner's 7 points, per
│                             version) · screenshots/ · LP User Guide.pdf (built from user-guide/)
├── Local Productivity/       the app's sources (synchronized folder → app target)
│   ├── App/                  AppModel (routes, navigation, glue) · AppSettings · Day/TimeOfDay
│   │                         · PageSession (load/save one page) · RootView · app entry + menus
│   ├── Workspace/            Workspace (tree, file ops, watcher, tasks, share grants) ·
│   │                         WorkspaceIndex (actor: metadata, tasks, search) · PageTasks (which
│   │                         to-dos are tasks; finding one again) · FileNode · FileWatcher ·
│   │                         WorkspaceLibrary (bookmarks) · Safety (PathSafety, LinkSafety,
│   │                         BoardIDSafety)
│   ├── Markdown/             Foundation-only engine: parser, serializer, inline parser/serializer,
│   │                         model, front matter
│   ├── Editor/               EditorController · EditorTextView (+Editing, +Input) · EditorTheme
│   │                         (type scale) · EditorStyler · EditorLayoutManager · DocumentConverter
│   │                         · overlays (slash menu, format bar) · PageView · PageHeaderView
│   ├── Boards/               BoardStore (one open board) · BoardView/BoardScreen · BoardsView
│   │   │                     (overview + New Board sheet) · CardDetailView · BoardProgressPanel
│   │   │                     · SharingServices · GistPublisher · GoogleDrivePublisher (sharing)
│   │   └── Model/            Foundation-only: BoardModel (Board, cards, CardText, templates,
│   │                         summaries) · BoardParser · BoardActivity (log, BoardShare, ShareTrust)
│   │                         · BoardReport · BoardLayout · GoogleDriveMapping
│   ├── Calendar/             CalendarView · EventEditorView
│   │   └── Sync/             CalendarSyncStore · providers (EventKit, Google, Microsoft) · OAuth
│   │                         · Foundation-only mappings and models
│   ├── Reminders/            ReminderPlanner (Foundation-only) · ReminderCenter (UserNotifications)
│   ├── Widgets/              WidgetPublisher (app side: writes the widget snapshot)
│   ├── Home/ Search/ Sidebar/ Settings/ Welcome/   screens
│   ├── Design/               Theme (colour tokens, Metrics, Font.lp, InterfaceScale) · Compatibility
│   └── Debug/                SnapshotHarness (scripted UI runs) · DemoCalendarProvider
├── LPWidgets/                the widget extension: Today and Board widgets, styling, sample data
├── Shared/                   compiled into BOTH targets: WidgetSnapshot (+ WidgetStore, LPLink)
├── UpdateCore/               compiled into the app AND LPUpdateInstaller: versions, the release feed, the
│                             signed update.json (Ed25519, `UpdateFeed.publicKeys`), the helper's protocol
├── LPUpdateInstaller/        XPC service embedded in LP.app (Contents/XPCServices), NOT sandboxed: checks an
│                             update again and swaps the app in (only LP may connect)
├── Tests/                    standalone suites (no Xcode needed): Markdown, Calendar, Safety,
│                             Widgets, Reminders, Tasks, Boards, Ownership — each a main.swift
├── Scripts/                  test, build, snapshot, demo/stress vaults, render widgets, deploy,
│                             rollback, signing team, user guide (brand renderer lives in ../LP Design/brand)
├── Local Productivity.entitlements      app entitlements file (app groups, bookmarks)
├── LPWidgetsExtension.entitlements      widget entitlements (app groups)
└── Local-Productivity-Info.plist         app Info.plist additions (URL scheme)
```

Other entitlements come from build settings (`ENABLE_APP_SANDBOX`, `ENABLE_RESOURCE_ACCESS_CALENDARS`,
`ENABLE_OUTGOING_NETWORK_CONNECTIONS`, `ENABLE_USER_SELECTED_FILES`, …).

Brand design materials live in the separate sibling folder **`../LP Design/brand/`**, with local
history only: [brand guide](<../LP Design/brand/README.md>), SVG masters, explorations, archives,
exports and the guarded `make-icon.swift` renderer. **08 — Orbit Bear** was chosen by the
owner on **20 November 2026** and is installed locally: a charcoal teddy with a light cyan
headset and progress ring. At 16/32 px, an enlarged head/headset replaces the full body/ring.
The head is also the logo mark, LP lockup and 120 px Google branding PNG. 07 Focus Bear and
09 Desk Bear remain explorations; 04/05/06 line art is archived there. The app repository
keeps only the installed catalog and guide PNGs. Do not recreate `design/` or the old renderer
under `Scripts/`.

## 4. Build, test, run, look

```sh
Scripts/test.sh                  # all suites; must be 0 failed (or: markdown | calendar | safety | widgets | reminders | tasks | search | boards | ownership)
LP_TEST_VERBOSE=1 Scripts/test.sh ownership   # every "person B" check printed (the security checklist's "prove it")
Scripts/build.sh                 # sandboxed Debug build (what Xcode produces); add LP_TEAM_ID=… to sign with a team
Scripts/build.sh harness         # unsandboxed Debug build used by the snapshot harness
Scripts/make-demo-vault.sh       # sample workspace in .build/demo-vault (dates relative to today)
Scripts/make-stress-vault.sh     # 3,000-note workspace for speed work (.build/stress-vault)
Scripts/snapshot.sh <name> "<step> ;; <step> ;; …"   # drive the real app; PNGs in .build/shots/<name>/
Scripts/render-widgets.sh        # draw the widgets light/dark into .build/shots/widgets (Xcode can't preview macOS widgets)
Scripts/signing-team.sh          # list signing teams for LP_TEAM_ID
Scripts/make-user-guide.sh       # rebuild docs/LP User Guide.pdf (WebKit prints, Core Graphics finishes)
swift "../LP Design/brand/make-icon.swift" --app . # SVGs → brand exports, app catalog, guide cover; add --check
swift "../LP Design/brand/make-icon.swift" --app . --self-test-guards # 26 temporary path/catalog guard cases
Scripts/make-site.py             # LP's public pages (home, privacy, terms…) from the policies → ../LTF-Git-Dev.github.io
Scripts/make-site-shots.sh       # the website's screenshots, light and dark, from the harness (crops by Scripts/site-image.swift)
Scripts/deploy.sh <x.y.z-beta.n> [--dry-run | --confirmed]   # a beta: pre-release from the branch, owner-confirmed only
Scripts/deploy.sh <x.y.z> [--dry-run | --confirmed]          # the official version from main, once the owner confirmed its beta
Scripts/rollback.sh [<version> [--source]]
```

`Scripts/test.sh` compiles each suite with `swiftc` against only the Foundation-only sources it
needs (see the script). That is why pure logic must stay Foundation-only and `nonisolated`.

The brand renderer finds its sources beside itself. Without `--app`, it defaults to the sibling
`../Local Productivity` relative to `LP Design`; an explicit app path is relative to the caller.
It writes only direct PNG children of brand `exports/`/`explorations/` and the app's exact icon
catalog/guide-images folders. All paths and the ten catalog mappings are preflighted before
writing; symlink destination files are refused and `Contents.json` is preserved. Add
`-module-cache-path /tmp/lp-brand-module-cache` after `swift` if the default cache is blocked.
In the builder Codex's sandbox, macro-dependent tests and the harness build can't run — that's
the sandbox, not LP. Claude verifies outside it: for the installed 08 (20 November 2026), the
build, all 927 tests (0 failed), `--check` (including the 120 px Google logo's size limit), the
26 guard self-tests and the guide PDF rebuild (cover looked at), and Orbit Bear seen in the built
app.

### The snapshot harness

`Debug/SnapshotHarness.swift` (Debug builds only) runs a scenario inside the real app when
`LP_SNAPSHOT_SCENARIO` is set — `Scripts/snapshot.sh` sets it. It uses throwaway preferences
(`AppModel(defaults: nil)`), never schedules real notifications, and never touches the user's
settings. Useful environment variables:

| Variable | Effect |
|---|---|
| `LP_WORKSPACE=<path>` | workspace to open (default `.build/demo-vault`; empty = welcome screen) |
| `LP_APPEARANCE=light\|dark` | appearance |
| `LP_SNAPSHOT_SIZE=1280x800` | window size |
| `LP_SNAPSHOT_ACTIVATE=1` | make the window active — needed for `keys:`, `shortcut:` and real mouse events |
| `LP_WIDGET_SNAPSHOT=<path>` | also write the widget snapshot JSON there (to render widgets from real data) |
| `LP_DEMO_CALENDAR_DELAY=<s>` · `LP_DEMO_CALENDAR_WRITE_DELAY=<s>` | the demo calendar answers late (with what it had when asked) · confirms changes late — races between syncing and editing |
| `LP_DEMO_CALENDAR_LIMIT=<s>[@<n>]` | the demo calendar's first (or n-th) fetch answers "too many requests, wait <s>" |

Steps (`name:argument`, separated by ` ;; `), grouped:

- **Navigation:** `open:<path>`, `route:home|calendar|boards|folder=<path>`, `new:`, `palette:<query>`,
  `settings:<general|editor|notifications|calendars|sharing>`, `url:<localproductivity link>`, `state`
- **Capture:** `shot:<name>`, `shot-other:<name>` (Settings window or a sheet), `shot1x`, `wait:<ms>`
- **Editor:** `type:`, `keys:` (real key events), `shortcut:cmd =` (real key event with modifiers,
  through the menus), `key:`, `find:`, `select:`, `format:`, `turn:`, `block:`, `dump`, `cat`, `layout`,
  `setting:size=17|spacing=relaxed|width=wide|font=serif|interface=small`, `text-size`
- **Boards:** `new-board:<folder>` (opens the sheet), `create-board:<name>|<template>|<folder>`,
  `board-add:<list>=<text>`, `board-move:<card>=<list>[@<before>]`, `board-card:<title>`,
  `board-progress[:off]`, `board-undo`, `board-log:<n>`, `mouse-drag:x1,y1>x2,y2`,
  `share-trust` / `share-forget` / `share-update` / `share-stop` (what the progress panel's sharing
  buttons do; harness runs never read the real GitHub token, so nothing reaches GitHub)
- **Calendar:** `demo-calendar`, `select-day:<offset>`, `event-editor:new|<title>`,
  `event-create:<title>@<dayOffset>@<hour>`, `event-update:`, `event-delete:`, `events:<filter>`,
  `calendar-sync` (the Sync button), `calendar-state` (each account's state, demo fetch count)
- **Reminders:** `reminders` (prints the plan), `reminder:<open|done|hour|tomorrow>=<title>` (acts as
  if tapped), `reminder-permission:<allowed|denied|ask>`
- **Files:** `write:<path>=<text>` (change a file behind the app's back), `link:`, `wiki:`
- **Performance:** `perf-load`, `perf-open:<path>`, `perf-type:<n>`, `perf-save`, `perf-search:<q>`,
  `perf-phases`, `perf-memory`

**Always look at the PNGs** after UI work — light, dark and a narrow window (~900×640).

## 5. Architecture in one page

```
                 ┌──────────── AppModel (MainActor, @Observable) ────────────┐
 RootView ──────▶│ route · back/forward · workspace · session · boardStore   │
 (SwiftUI)       │ reminders (ReminderCenter) · widgets (WidgetPublisher)    │
                 └───────┬───────────────┬──────────────────┬────────────────┘
                         │               │                  │
                 Workspace (tree,   PageSession       BoardStore          CalendarSyncStore
                 watcher, files)    (one page)        (one board)         (app-wide)
                         │               │                  │                  │
                 WorkspaceIndex     EditorController   BoardParser /       providers: EventKit,
                 (actor) → meta:    + EditorTextView   BoardActivity /     Google, Microsoft
                 titles, tasks,     ↔ DocumentConverter BoardReport        (OAuth PKCE, Keychain)
                 boards, search     ↔ Markdown engine
                         │
                         └──▶ meta changes ──▶ scheduleGlanceUpdate() ──▶ ReminderPlanner → system
                                                                       └▶ WidgetSnapshot → App Group → widgets
```

### Routes (`App/AppModel.swift`)

| Route | Screen |
|---|---|
| `.home` | `HomeView` — greeting, quick actions, recent pages, open tasks |
| `.calendar` | `CalendarView` |
| `.boards` | `BoardsView` — every board with progress; New Board |
| `.folder(path)` | `FolderView` |
| `.page(path)` | `PageView` (editor) with a `PageSession` |
| `.board(path)` | `BoardScreen` with a `BoardStore` |

`openPage(path)` picks `.board` or `.page` by sniffing front matter for `kanban-plugin:`.

### Workspace and index

- The user picks a folder; LP keeps a security-scoped bookmark (`WorkspaceLibrary`).
- `WorkspaceScanner` builds the `FileNode` tree, skipping hidden entries (`.lp/`, `.obsidian/`, `.git/`).
- `FileWatcher` (FSEvents) → rescan → `onPagesChangedOnDisk` reloads an open page or board.
- `WorkspaceIndex` (actor) reads changed files **in parallel batches** and keeps `PageMeta` per page:
  title, icon, snippet, date, word count, tasks (`TaskItem` with `due`, `dueTime`), and for boards a
  `BoardSummary`. Search runs on text folded once at index time. ⌘K (`Search/CommandPalette`) lists
  pages whose name holds every word under "Pages" and every other match under "In pages"
  (`SearchHit.inPages`, tested by the `search` suite), including pages that match partly by name.
- `Workspace.meta` changes fire `onMetaChanged`; `hasIndexed` says the first pass is complete.

### Editor

- The `NSTextView` storage holds the **rendered** document: one paragraph per block, no syntax.
  Block kinds and inline styles are custom attributes.
- `EditorStyler` derives fonts/colours after each edit (in `didProcessEditing`, never in
  `willProcessEditing`); `EditorLayoutManager` draws markers, panels and chips.
- `DocumentConverter` maps blocks ↔ attributed storage; `MarkdownSerializer` writes the file.
  Per-block "trivia" (blank lines, indentation, markers) keeps untouched text byte-identical.
- `EditorTheme` holds the whole type scale, derived from one **text size** (default 15 pt, 12–24)
  and a **line spacing** multiplier; typefaces: system, rounded, serif (New York), mono, or any
  installed family.
- Saving (`PageSession.save`) is debounced 0.7 s after typing, uses a per-page `SerializerCache`
  (unchanged paragraphs are not re-serialized), and writes atomically with `SafeFileWriter`.
- **No lost work:** before writing, the file is compared with what was read (another app's
  version is kept as a copy first); an unreadable page is read-only; leaving a page, the
  workspace or the app goes through `AppModel.leavePage()` / `closeSavingChanges()`, which keeps
  unsaved edits in `Application Support/LP/Recovered` (`RecoveredCopies`) or keeps the page open.

### Boards

- **Format:** Obsidian Kanban (see §6). `BoardParser` keeps unknown lines and the settings block.
- **Store:** `BoardStore.perform` takes in changes made elsewhere first (`catchUpWithDisk`),
  mutates a copy, **writes the file before anything else**, registers undo and records
  `BoardEvent`s (diffed by card ID). History lives in `.lp/boards/<board-id>.json`
  (`BoardActivityLog`, read leniently so another version's additions never wipe it; it records
  its file — `path`, `fileHasID`). Unreadable or non-UTF-8 boards are read-only.
- **Identity:** `BoardStore.historyID` is the one rule for which ID a board's history and sharing
  go by — its `lp-board`, unless it is a copy made outside LP (then an unused ID of its own,
  written on its first save), or, for a board never saved, an ID from its path unless that
  history is another file's. LP moves boards through `Workspace.moveWithBoards`: every board under
  the path is checked first, then their IDs are written into the front matter (nothing else
  changes; a board changed meanwhile stops the move) and their histories are told the new place
  before the file moves — if any step can't be done, nothing moves. Details in
  `docs/ARCHITECTURE.md` §5.
- **UI:** `BoardView` lists cards in lanes sized by `BoardLayout` (responsive: lanes share the
  width between 260 and 340 pt; the progress panel sits beside the lists when the window is wide
  and floats over them when narrow). Dragging is an in-app `DragGesture` with frame preferences
  (`BoardCardDrag`, `BoardDropTarget`) — one code path on macOS 15–27.
- **Overview:** `BoardsView` shows every board (`PageMeta.board`) as a card; `NewBoardSheet`
  creates boards from `BoardTemplate` (Simple, Project, Weekly, Content, Bugs).
- **Sharing:** `BoardReport.markdown` → `GistPublisher` creates/updates a **secret** GitHub Gist
  with the user's token (Keychain); `BoardReport.html` exports a report. Card notes are never shared.
  The share record in `.lp/` is untrusted: LP updates or deletes a page only when this Mac holds
  a grant for it (`Workspace.authorizeShare`, keyed by path, board ID and gist; given when
  publishing or on "Keep It Updated From Here") — `BoardStore.shareIsTrusted`. Links come from
  `BoardShare.pageURL`.

### Calendar

`CalendarSyncStore` syncs each provider (`CalendarProvider` protocol) in full — a year back to two
years ahead, plus the months shown — about every 30 minutes while LP runs and is online (Google
and Outlook; Apple Calendar is read from macOS as needed), refreshes the months
shown on launch, activation, every 5 minutes and after edits, keeps what it fetched until the
account is disconnected (`SyncEvent.merging`), and caches it to Application Support. Timed events are instants; all-day events are floating days.
Writes go back to the source calendar; Google uses etags (`If-Match`).

### Reminders (`Reminders/`)

- `ReminderPlanner.plan(tasks:events:settings:now:)` — pure: a reminder for each open task/card on
  its due day (at its own time or the default), alerts before timed events (Apple Calendar events
  only if asked — Calendar alerts for them already), and a morning summary that skips empty days.
  Seven days ahead, at most 64 (macOS's limit), identifiers are stable FNV hashes so unchanged
  reminders are left alone.
- `ReminderCenter` hands the plan to `UNUserNotificationCenter` (diffing pending requests), asks
  permission the first time there is something to remind about, registers actions (Mark as Done,
  Remind Me in an Hour, Remind Me Tomorrow) and forwards responses to `AppModel.handleReminder`.
  The delegate is `nonisolated` and hops to the main actor. `dryRun` (harness/previews) never
  touches the system.
- Settings → Notifications shows the permission state and what is actually waiting.

### Widgets (`LPWidgets/`, `Shared/`, `Widgets/`)

- The app builds a `WidgetSnapshot` (due/overdue items, events, board summaries) and
  `WidgetPublisher` writes it as JSON into the **App Group container**
  `<TeamID>.LTF.Local-Productivity`, then reloads timelines — only when something shown changed.
- **Team requirement:** on macOS 15+ only a team-signed app can share a group container without
  a consent prompt. `WidgetStore` reads the team from the running code's own signature; when LP is
  signed ad hoc it never touches the container and the widgets show a "set up" message.
- Widgets: `TodayWidget` (small/medium/large) and `BoardWidget` (small/medium, board chosen via
  `BoardWidgetIntent`). Taps open `localproductivity://home|boards|calendar?day=|open?path=` links,
  handled by `AppModel.handle(_:)` — **navigation only**, paths checked with `PathSafety`.

### Settings and type

`AppSettings` (UserDefaults-backed, `@Observable`) holds appearance, editor font/family, text
size, line spacing, page width, interface size, spelling, daily-notes folder and reminder options.
Interface text uses `Font.lp(size:weight:design:)`, which scales by `InterfaceScale.shared` so
the sidebar, lists, boards, Home and calendar follow Settings → Editor → Interface size.
View menu: Make Text Bigger (⌘+/⌘=), Smaller (⌘−), Default (⌘0).

## 6. File formats

**Notes** — CommonMark plus Obsidian: `[[wiki links]]`, `![[embeds]]`, callouts (`> [!note]`),
`==highlight==`, `%%comments%%`, footnotes, math and HTML (kept verbatim), YAML front matter
(`icon:`, `date:` are read).

**Tasks** — `- [ ] text 📅 2026-11-20` (Obsidian Tasks); `due: 2026-11-20` also works. A time
after the date sets the reminder time: `📅 2026-11-20 14:30`, `2:30 pm`, `9am`.

**Boards** — Obsidian Kanban:

````markdown
---

kanban-plugin: basic
lp-board: bdemolaunch        ← LP's stable board ID (history file name)
icon: 📋

---

## In progress

- [ ] Finish the pricing page #web @{2026-11-20} @@{16:00} ^cip1
	Notes under the card, indented with a tab.

## Done

**Complete**
- [x] Choose a launch date ^cdn1

%% kanban:settings
```
{"kanban-plugin":"basic"}
```
%%
````

`^cip1` is the card ID (an Obsidian block ID); `@{date}` the due date; `@@{HH:mm}` the due time;
`**Complete**` makes a list count its cards as done. Each list is followed by two blank lines.
A card copied with its ID gets a new ID on the next save; notes above a list's first card and
under the archive are kept in place.

**Board history** — `.lp/boards/<board-id>.json`: events, daily snapshots, first-seen dates, the
share record, and `lastSeen` (the board as last seen, to record outside edits).

**Widget snapshot** — `widget-snapshot.json` in the App Group container (`WidgetSnapshot`, ISO 8601 dates).

## 7. Concurrency and SDK 27 rules

- Default actor isolation is **MainActor**. Pure logic (Markdown, board model, planners, mappings,
  `Day`) is `nonisolated` so tests and background work can use it.
- System callbacks that may arrive off the main thread (notifications) go to a `nonisolated`
  object that copies plain values and hops with `Task { @MainActor in … }`.
- `@State` is a macro in SDK 27: set initial values in `init` with `_x = State(initialValue:)` and
  do not also give the property a default.
- Sheets that edit something initialise their fields in `init`, not `onAppear`.
- APIs newer than macOS 15 go through helpers in `Design/Compatibility.swift` (`#available`).
- Menu `Commands` are not reliably redrawn when observed values change — don't depend on
  `.disabled(...)` in commands for state that changes often.

## 8. Security model

| Concern | How it is handled |
|---|---|
| Files | Sandbox; only the user-chosen folder (bookmark) and files picked in panels. Every create/move path goes through `PathSafety.contained` (no `..`, no absolute paths) and `PathSafety.resolvesInside` (no escaping through a linked folder) |
| Shared pages | Through the person's own accounts only — a secret gist (their token) or a Google Doc in their Drive (`drive.file` only). Only pages this Mac published or was allowed to keep up to date — one decision, `ShareTrust.isTrusted`, pinned by the `ownership` suite; IDs validated per service; links built on github.com / docs.google.com; disconnecting a Google account deletes its Docs first |
| Reminders | Carry their workspace ID; never act on another workspace |
| Links in notes | `LinkSafety`: http/https/mailto open; other schemes ask first; `file:` opens documents only, anything runnable is revealed in Finder |
| Board IDs | `BoardIDSafety.isValid` (they name a file in `.lp/boards/`) |
| Deep links | `localproductivity://` only navigates; paths are contained and must exist |
| Secrets | OAuth and GitHub tokens in the Keychain; client IDs are public (PKCE, no secrets) — LP's own in `BuiltInRegistration.swift`, or the person's own |
| Release signing | Hardened runtime; `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` for Release (no `get-task-allow`) |
| Widgets | Group container used only when team-signed (no consent prompts, no cross-app access) |
| Network | Outgoing only: Google, Microsoft, GitHub APIs. No analytics, telemetry or servers of ours |
| Service limits | "Too many requests" (`RateLimit.retryDate`) is honoured: `ServicePause` keeps the wait per calendar account and per GitHub token (at most an hour, never shortened by a later answer), and every request checks it first; automatic share updates retry at most 3 times |
| Published apps | `deploy.sh` refuses an app whose signature shows an email address or that contains a token or key; the official version is the tested beta's own zip; Release builds contain no harness code |
| Checklist | The owner's security checklist (`docs/SECURITY_CHECKLIST.md`) is run before every version is finalized, and its result recorded there |
| Connected accounts | Least privilege (Google calendar list read-only + events; Microsoft calendars, no profile), only the fields shown, private sign-in, revoke on disconnect (Google). Pinned by the calendar tests; documented in `PRIVACY.md` and `docs/CONNECTED_ACCOUNTS.md` |

## 9. Tests

| Suite | Checks | Covers |
|---|---|---|
| `markdown` | 365 | parsing, serializing, byte-exact round trips, escaping (link titles), fences, paragraph cache, fuzzing (4,000 random + 3,000 realistic notes) |
| `calendar` | 146 | Google/Microsoft mappings, OAuth core, full-sync merging, "slow down" answers and waits |
| `safety` | 63 | paths (including through linked folders), links, board IDs, sharing grant keys |
| `widgets` | 18 | snapshot reading, storage, deep links |
| `reminders` | 62 | time parsing, planning rules, limits, stable identifiers, workspaces |
| `tasks` | 24 | which to-dos are tasks; finding the right one to tick off after the page changed |
| `boards` | 220 | Kanban format, edits, card edits, moving cards, list IDs, front matter, diffing, logs (lenient decoding), reports, gist links, Drive requests and shared-page records, templates, layout, drop targets, fuzzing (3,000 random boards) |
| `ownership` | 29 | person A makes something, person B tries to change it: shared pages on GitHub and in Google Drive (permissions per Mac), sign-in replies, `localproductivity://` links — every attempt refused (`LP_TEST_VERBOSE=1` prints them) |

Add a test for every parser, serializer or model change. The bar for the Markdown engine is
byte-for-byte round trips of untouched text.

## 10. Workflow you must follow

The owner's rules (full text in `CLAUDE.md` and `AGENTS.md`): **no release without the owner's
confirmation, and every version a beta first**, **every session updates the documentation**,
**Codex reviews every finished task** before a release is proposed, and **the security checklist**
runs before any version is finalized.

1. Work on a sub-branch (`feature/…`, `fix/…`, `docs/…`); never commit to `main` directly.
2. Keep changes small and in the surrounding style; Foundation-only for pure logic.
3. Verify: `Scripts/test.sh` (0 failed), `Scripts/build.sh` (no new warnings), and for UI the
   harness screenshots in light, dark and narrow — and actually look at them.
4. Commit with a clear message; push the branch.
5. Update the documents: `CHANGELOG.md` (an entry under Unreleased), `README.md`, the user guide
   (`docs/user-guide/guide.html` → `Scripts/make-user-guide.sh` → `docs/LP User Guide.pdf`) when
   anything visible changed, `CLAUDE.md`, `AGENTS.md`, this file and `docs/`.
6. Get the work reviewed: Claude asks the Codex agent in the right-hand Herdr panel to review the
   code base (as the reviewer, follow `AGENTS.md` §7). The findings are fixed with tests, the fixes
   checked again by Codex, and everything tested again.
7. Run the security checklist (`docs/SECURITY_CHECKLIST.md`) and record the version's result.
8. Ask the owner for a beta, naming it. Only after they say yes: set `MARKETING_VERSION` (project
   level), move the Unreleased lines of `CHANGELOG.md` under `## <version> — <date>` (they become the
   release notes), push, and run `Scripts/deploy.sh <version>-beta.<n> --confirmed` (try
   `--dry-run` first): a pre-release from the branch. Only when the owner confirms the beta works:
   merge into `main` and run `Scripts/deploy.sh <version> --confirmed` — refused unless the app is
   exactly the newest beta. Both refuse to continue until the official release being replaced is
   published with its app — the way back is always kept.
9. Roll back with `Scripts/rollback.sh`. Never force-push, delete tags or delete releases unless
   the owner asks for exactly that. The repository is public: commit only as GitHub's noreply identity.

## 11. Recipes

**Add a block type** — `BlockKind` (Markdown/MarkdownModel.swift) → parser and serializer (with
round-trip tests) → `DocumentConverter` → `EditorStyler`/`EditorTheme` (font, spacing) →
`EditorLayoutManager` if it draws → slash menu in `EditorOverlays`.

**Add a setting** — property + key + default in `AppSettings` (store in `didSet`; carry over any
older key) → UI in `Settings/` → read it where needed (views re-render through Observation; the
editor re-applies in `EditorHost.updateNSViewController`) → harness `setting:` if useful.

**Add a board template** — a case in `BoardTemplate` (title, lists, symbol) → it appears in the
New Board sheet automatically → the boards suite checks it parses and round-trips.

**Add a reminder kind** — extend `ReminderPlanner` (pure, tested in `Tests/ReminderTests`) →
category/actions in `ReminderCenter` → handling in `AppModel.handleReminder`.

**Add a widget** — view + provider in `LPWidgets/`, data in `WidgetSnapshot` (both targets compile
`Shared/`), filled by `AppModel.widgetSnapshot(for:)` → add to `LPWidgetsBundle` → render with
`Scripts/render-widgets.sh` → test the snapshot logic in `Tests/WidgetTests`.

**Add a harness step** — a `case` in `SnapshotHarness.perform`; print results with a recognisable
prefix so scripts can grep them.

## 12. Pitfalls (learned the hard way)

- **In-app updates** (`Local Productivity/Updates/`, `UpdateCore/`, `LPUpdateInstaller/`): the app is
  sandboxed and can't replace itself or even see whether its folder is writable — only the helper
  decides that. The helper trusts nothing from the app (re-verifies update.json, copies the zip
  before hashing it, checks bundle ID, version, build and the code signature). In the Xcode 27
  project format the helper is embedded by a copy phase with `"bundle-base-path":
  "contents-directory"` and `"relative-path": "XPCServices"` (`subpath`/`path`/`destination`
  are silently ignored). Releases are signed with the key in the owner's Keychain
  (`Scripts/release-key.swift`); a beta and its official release are the same app (same build
  number), so the updater never offers the official release of the beta you have. Debug-only
  test switches: `LP_UPDATE_FEED`, `LP_UPDATE_TEST_KEY`, `LP_UPDATE_AUTOINSTALL`; harness
  `update-demo:<state>`.

- Never restyle text in `willProcessEditing`; style in `didProcessEditing`, then `fixFontAttribute`.
- The editor storage always ends with a newline; line breaks inside a block are U+2028.
- Block spacing is set in `EditorTextContainer` against a fixed target; adding to the proposal doubles gaps.
- Presentation-only attributes (`.lpDueDate`) must be in `lpDerivedKeys` and never affect saving.
- Text from the editor is bridged `NSString`; make it native (`makeContiguousUTF8()`) before
  walking it character by character — otherwise saving a long note takes seconds.
- Board mutations must not read and write the same array element in one access (exclusivity).
- A board's history and sharing must only ever be keyed through `BoardStore.historyID`; path-derived
  IDs and copies made in Finder broke them in many small ways before that rule existed.
- The share record in a workspace's `.lp/` folder can be forged: never publish, update, delete or
  open anything from it without `shareIsTrusted` / `BoardShare.pageURL`. The decision is
  `ShareTrust.isTrusted`; change it only with the `ownership` tests. Harness runs never read the
  real GitHub token — keep it that way.
- A 403 isn't always "not allowed": GitHub and Google also use it for "too many requests". Go
  through `RateLimit.retryDate` before mapping a status to an error, and send every Google,
  Microsoft or GitHub request through `AuthorizedClient` / `GistPublisher.send`, which honour
  `ServicePause`.
- In Swift `"\r\n"` is one `Character`; split `unicodeScalars` to keep Windows line endings.
- A SwiftUI view's `init` runs on every parent redraw: what a sheet remembers from when it opened
  must be `@State`, not `let`.
- Whether a file is a board is decided only by `BoardParser.isBoard(head:)` (bytes, first 1 KB);
  don't add another sniffer.
- Two `ForEach` rows with the same id in one lazy stack collide; card IDs must be unique (the
  parser renames copies).
- Scripted harness steps produce no events, so undo groups don't close by themselves; board steps
  post an event.
- `ImageRenderer` can't draw AppKit-backed views (`Link`, `ProgressView`); the widget renderer sets
  `isDrawingSnapshot` and widgets use the drawn `ProgressBar`.
- Xcode cannot preview macOS widgets — use `Scripts/render-widgets.sh`.
- Synthetic key events must carry Shift in `charactersIgnoringModifiers` like real ones.
- `xcodebuild` auto-creates schemes in memory; the Xcode tools need the shared scheme
  (`xcshareddata/xcschemes/Local Productivity.xcscheme`).
- Set `MARKETING_VERSION` before a version's beta: the official release is refused when any app
  file — the project included — differs from the newest beta's.
- The user guide is printed by WebKit, which ignores `break-after: avoid` and misplaces floats that
  cross a page (see the comment at the top of `docs/user-guide/guide.html`); PDFKit's writer drops
  bookmarks and link targets, so `make-user-guide.swift` finishes the PDF with Core Graphics.

## 13. Known limitations and roadmap

- Widgets show data only when LP is signed with a team (a free Apple ID works) — see README.
- Notifications need the user's permission (asked the first time there is something to remind about).
- Tables are edited in a sheet; renaming a page does not update `[[links]]`.
- Google will connect with one click through LP's own registration (`BuiltInRegistration`,
  `docs/REGISTERING_LP.md`); until Google approves LP, `googleAwaitingReview` blocks new sign-ins
  and Drive grants through it (also when pasted as one's own ID; saved connections keep syncing); Microsoft still needs the user's own client ID until LP registers
  there. Work/school Microsoft accounts may need their organisation's approval.
- Progress sharing needs the person's own Google Drive (a connected Google account that allowed
  `drive.file`; with their own client ID, also the Drive API on in their Google Cloud project) or a
  GitHub token (gist scope).
  No OneDrive (it would need all files) or iCloud (no public-link API).
- Next (1.1): backlinks and an outline, links updated on rename, a week view, in-place tables.

## 14. Glossary

| Term | Meaning |
|---|---|
| Workspace / vault | The user-chosen folder of Markdown files |
| Block | One paragraph-level element: heading, paragraph, list item, to-do, quote, callout, code… |
| Run | A span of inline text with one style (bold, link, code…) |
| Trivia | Source formatting kept per block (blank lines, indentation, markers) for byte-exact saves |
| Lane / list | A board column (`## Title`) |
| Card ID | Obsidian block ID (`^c…`) that identifies a card across moves and edits |
| Glance update | Re-planning reminders and refreshing widgets after a change (`scheduleGlanceUpdate`) |
| Harness | The Debug-only scripted UI runner (`SnapshotHarness`) |
