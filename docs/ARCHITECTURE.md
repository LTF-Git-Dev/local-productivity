# LP — Architecture

How LP is put together, where each responsibility lives, and the formats it reads and writes.
For a guided tour of the whole repository, start with [`CODEX.md`](../CODEX.md).

## 1. Overview

```
┌──────────────────────────────── LP.app (sandboxed, SwiftUI + AppKit) ───────────────────────────────┐
│                                                                                                      │
│  App/            AppModel (routes, navigation, glue) · AppSettings · Day/TimeOfDay · commands        │
│     │                                                                                                │
│     ├── Workspace/   Workspace (tree, file ops, watcher, tasks) · WorkspaceIndex (actor: metadata,   │
│     │                tasks, board summaries, search) · FileWatcher · WorkspaceLibrary · Safety       │
│     │                                                                                                │
│     ├── Editor/      PageSession (load/save one page) · EditorController · EditorTextView (TextKit 1)│
│     │       └──────▶ Markdown/  MarkdownParser · MarkdownSerializer · InlineParser (Foundation-only) │
│     │                                                                                                │
│     ├── Boards/      BoardStore (one open board) · BoardView/Screen/ProgressPanel · BoardsView       │
│     │       │        (overview, New Board) · GistPublisher                                            │
│     │       └──────▶ Boards/Model/  BoardParser · BoardActivity · BoardReport · BoardLayout          │
│     │                               · templates · summaries (Foundation-only)                        │
│     │                                                                                                │
│     ├── Calendar/    CalendarView · EventEditorView                                                  │
│     │       └──────▶ Calendar/Sync/  CalendarSyncStore · providers (EventKit, Google, Microsoft)     │
│     │                                 · OAuth (PKCE, Keychain) · mappings (Foundation-only)          │
│     │                                                                                                │
│     ├── Reminders/   ReminderPlanner (Foundation-only) · ReminderCenter (UserNotifications)          │
│     ├── Widgets/     WidgetPublisher ──▶ Shared/WidgetSnapshot (compiled into both targets)          │
│     │                                                                                                │
│     └── Sidebar/ Home/ Search/ Settings/ Welcome/ Design/   screens and shared styles                │
│                                                                                                      │
│  PlugIns/LPWidgetsExtension.appex — LPWidgets/: Today and Board widgets (reads the snapshot)        │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
        │ files (user-selected folder)     │ EventKit / HTTPS          │ HTTPS          │ system
        ▼                                  ▼                           ▼                ▼
  The vault: *.md, attachments,     Apple Calendar · Google      GitHub Gists      Notification Center,
  .lp/boards/*.json                 Calendar API · Graph         (shared progress) App Group container
```

Rules that shape the code:

- **Default actor isolation is MainActor** (build setting). UI, models and stores run on the main
  actor. Pure logic that tests or background work need is marked `nonisolated`.
- **Pure cores are Foundation-only** — `Markdown/`, `Boards/Model/`, the calendar mappings,
  `OAuthCore.swift`, `Day.swift`, `Reminders/ReminderPlanner.swift`, `Workspace/Safety.swift` and
  `Shared/WidgetSnapshot.swift` — so `Scripts/test.sh` compiles and tests them without Xcode.
- **The file on disk is the source of truth.** Views render models; models are derived from files
  and written back to files. Nothing important lives only in memory or in preferences.
- **macOS 15 is the floor.** Newer APIs (Liquid Glass toolbars, scroll-edge effects) go through
  `#available` helpers in `Design/Compatibility.swift`.

## 2. Navigation and state

`AppModel` (`App/AppModel.swift`) owns the open `Workspace`, the current `Route`, back/forward
stacks, the per-route stores, the `ReminderCenter` and the `WidgetPublisher`:

| Route | Screen | Store |
|---|---|---|
| `.home` | `HomeView` | — |
| `.calendar` | `CalendarView` | `CalendarSyncStore` (app-wide) |
| `.boards` | `BoardsView` | — (reads `PageMeta.board`) |
| `.folder(path)` | `FolderView` | — |
| `.page(path)` | `PageView` | `PageSession` |
| `.board(path)` | `BoardScreen` | `BoardStore` |

`openPage(path)` chooses `.board` or `.page` by sniffing the file's front matter
(`kanban-plugin:`), so every way of opening a file (sidebar, Home, search, links, widgets) lands
on the right screen. Routes are rebased when files are renamed or moved, and restored per workspace.

`localproductivity://` links (`Shared/WidgetSnapshot.swift`, `LPLink`) open Home, Boards, a
calendar day, or a page; `AppModel.handle(_:)` only navigates and checks paths with `PathSafety`.

**Glance updates.** Whenever pages, calendar events or reminder settings change,
`scheduleGlanceUpdate()` (debounced 1 s) re-plans reminders and refreshes the widget snapshot.
Nothing is planned before the workspace has been indexed once (`Workspace.hasIndexed`).

## 3. Workspace

- **Access:** the user picks a folder (`NSOpenPanel`); LP keeps a security-scoped bookmark
  (`WorkspaceLibrary`). Sandbox entitlements: user-selected read/write, app-scoped bookmarks.
- **Scanning:** `WorkspaceScanner` builds the tree, skipping hidden files (so `.lp/`, `.obsidian/`
  and `.git/` never appear).
- **Watching:** `FileWatcher` (FSEvents) reports changes; the workspace rescans and tells the open
  page or board to reload (`onPagesChangedOnDisk`), ignoring dot-folders.
- **Indexing:** `WorkspaceIndex` (an actor) reads changed files in **parallel batches**: title,
  icon, snippet, date, tasks (with due day and time), word count and search text. Title and body
  are folded (case and accents) once at index time, so search is a plain scan. Boards are indexed
  through `BoardParser`: a snippet, a `BoardSummary` (total, done, lists, open due dates) and their
  dated cards as tasks.
- **Writing:** `SafeFileWriter` replaces files atomically (`replaceItemAt`), keeping creation dates
  and Finder tags. Every path LP creates or moves to goes through `PathSafety.contained`.

## 4. Editor

A TextKit 1 `NSTextView` whose storage holds the **rendered** document — one paragraph per block,
no Markdown syntax. Block kinds and inline styles are custom attributes; `EditorStyler` derives
fonts and colours from them after every edit; `EditorLayoutManager` draws markers, panels and
chips; `DocumentConverter` maps blocks ↔ storage; `MarkdownSerializer` writes the file. Untouched
text keeps its original bytes through "trivia" carried on each block.

- **Type** comes from `EditorTheme`, derived from one text size (default 15 pt, 12–24) and a line
  spacing multiplier: headings ×1.75/1.4/1.2/1.07, title ×2.15, gaps and indents scaled to match.
  Typefaces: system, rounded, serif, mono, or any installed family (`NSFontManager`).
- **Saving** (`PageSession`) waits 0.7 s after typing, serializes with a per-page
  `SerializerCache` (unchanged paragraphs are reused; a background pass warms it when a long page
  opens) and writes only when the text changed.

Details and pitfalls: `CLAUDE.md`.

## 5. Boards

**Format** — Obsidian Kanban (`Boards/Model/BoardParser.swift`):

````markdown
---

kanban-plugin: basic
lp-board: bdemolaunch        ← LP's stable board ID (added on first save)
icon: 📋

---

## In progress

Notes about this list stay above its cards.
- [ ] Finish the pricing page #web @{2026-11-20} @@{16:00} ^cip1   ← ^cip1 = card ID; @@{…} = time
	Notes under the card, indented with a tab.
	- [ ] A checklist item

## Done

**Complete**                                               ← cards here count as done
- [x] Choose a launch date ^cdn1

%% kanban:settings
```
{"kanban-plugin":"basic"}
```
%%
````

- Parsing keeps unknown lines (`leadingLines`, `extraLines`, `archiveLines`, `preamble`) and the
  settings block verbatim; a board written by the plugin round-trips byte for byte.
- Card IDs come from block IDs; cards without one — or copied with another card's ID — get a new
  ID that is written on the next save. A `---` inside a card's notes is part of the notes.
- Card text edits change only the relevant token (`CardText.settingDue/Tags/Title`).
- `BoardTemplate` creates new boards (Simple, Project, Weekly, Content, Bugs) in the same layout.

**Runtime** — `BoardStore` (`Boards/BoardStore.swift`):

1. Every change goes through `perform(_:undoManager:change:)` — mutate a copy, write the file,
   register undo, record activity.
2. `BoardDiff.events(from:to:)` compares old and new boards by card ID → `BoardEvent`s.
3. The activity log `.lp/boards/<board-id>.json` (`BoardActivityLog`) holds events, daily
   snapshots (total/done), first-seen dates, the share record and `lastSeen`. It is decoded
   leniently: a part another version wrote that cannot be read is skipped, never the whole log.
4. External edits (`reloadFromDisk`) are diffed and recorded the same way.

**UI** — `BoardView` lays lists out with `BoardLayout`: lists share the width between 260 and
340 pt; past that the row scrolls. The progress panel sits beside the lists from 960 pt and
floats over them below. Dragging is in-app (`DragGesture` + frame preferences: `BoardCardDrag`,
`BoardDropTarget.find`) so one code path works on macOS 15–27 and synthetic events can test it;
text dragged in from other apps becomes new cards. `BoardsView` shows every board as a card and
hosts `NewBoardSheet`.

**Sharing** — `BoardReport.markdown` renders the progress page; `GistPublisher` creates/updates a
**secret** GitHub Gist with the user's token (Keychain). Updates are debounced (4 s) after changes.
`BoardReport.html` produces the exported report. Card notes are never included.

## 6. Calendar sync

```
CalendarView ──▶ CalendarSyncStore ──▶ CalendarProvider (protocol)
                  (cache, polling,        ├─ EventKitCalendarProvider   (Apple; macOS syncs iCloud/Exchange/CalDAV)
                   optimistic edits)      ├─ GoogleCalendarProvider     (Calendar API v3)
                                          └─ MicrosoftCalendarProvider  (Microsoft Graph v1.0)
```

- **Model** (`CalendarSyncModels.swift`): `CalendarAccount`, `SyncCalendar`, `SyncEvent`,
  `EventDraft`. Timed events are absolute instants; all-day events are floating (local midnight to
  the midnight after the last day).
- **Auth** (`OAuth.swift`, `OAuthCore.swift`): authorization code + PKCE in
  `ASWebAuthenticationSession`; tokens in the Keychain (`OAuthTokenStore`), refreshed before
  expiry; one retry on 401. Google uses an "iOS" OAuth client (reverse-client-ID redirect);
  Microsoft uses the `msauth.<bundle id>://auth` redirect.
- **Mapping** (`GoogleCalendarMapping.swift`, `MicrosoftGraphMapping.swift`): pure translation of
  URLs, responses and request bodies — covered by 63 tests.
- **Sync** (`CalendarSyncStore.swift`): loads a window around the visible month; refreshes on
  launch, activation, every 5 minutes, on `EKEventStoreChanged`, and after edits; caches to
  `~/Library/Containers/…/Application Support/LP/calendar-cache.json`; edits apply optimistically
  and roll back if the provider refuses. `onEventsChanged` triggers a glance update.
- **Writes** go to the source calendar. Google uses `If-Match` etags; repeating events can be
  changed for one occurrence or the whole series.

## 7. Reminders and notifications

```
AppModel.reminderPlan(for:) ──▶ ReminderPlanner.plan (pure) ──▶ ReminderCenter.update ──▶ UNUserNotificationCenter
   open tasks + cards with dates     reminders · event alerts ·        diff pending requests,
   visible calendar events           summaries, ≤ 64, 7 days           ask permission once
                                                                         │
AppModel.handleReminder ◀── ReminderDelegate (nonisolated) ◀────────────┘  taps and buttons
   open · mark done (Workspace.toggleTask) · snooze
```

- **Planning** (`ReminderPlanner`): a reminder on each open item's due day (its own time, or the
  default 9:00); alerts before timed events (default 10 min; Apple Calendar's own events are left
  to Calendar unless included); a morning summary (default 8:30) that is skipped when there is
  nothing due, overdue or on the calendar. Identifiers are stable FNV-1a hashes of what is shown,
  so unchanged reminders stay as they are and edited ones are replaced.
- **Delivery** (`ReminderCenter`): reminders wait with the system and arrive when LP is closed.
  Categories carry Mark as Done / Remind Me in an Hour / Remind Me Tomorrow. Snoozed reminders
  use their own prefix and survive re-planning. In snapshots and previews (`dryRun`) nothing is
  scheduled and no permission is requested.
- **Handling:** Mark as Done saves an open page first, then ticks the box in the file; actions
  that arrive while LP is still launching wait for the workspace to be indexed.

## 8. Widgets

- **Extension:** `LPWidgetsExtension` (`LPWidgets/`) — `TodayWidget` (small, medium, large) and
  `BoardWidget` (small, medium; board chosen with `BoardWidgetIntent`/`BoardEntity`). Timelines
  add entries every 15 minutes and just after midnight; the app reloads them on change.
- **Data:** `AppModel.widgetSnapshot(for:)` builds a `WidgetSnapshot` (due and overdue items,
  events for two weeks, board summaries); `WidgetPublisher` writes it to
  `<App Group>/widget-snapshot.json` only when something shown changed.
- **App Group:** `<TeamID>.LTF.Local-Productivity` (entitlement `$(TeamIdentifierPrefix)…`).
  `WidgetStore` reads the team from the running code's own signature; with an ad-hoc signature it
  never opens the container (macOS 15+ would ask the user, and a widget cannot), and the widgets
  explain that LP must be signed with a team. `LP_TEAM_ID` in the build scripts signs with one.
- **Checking:** Xcode cannot preview macOS widgets; `Scripts/render-widgets.sh` renders them with
  `ImageRenderer` from sample data or from a snapshot the app wrote (`LP_WIDGET_SNAPSHOT`).

## 9. Security and privacy

| Concern | How it is handled |
|---|---|
| File access | Sandbox; only the user-chosen folder (bookmark) and files picked in open/save panels. Created and moved paths are contained (`PathSafety`); attachments resolve only inside the workspace |
| Links in notes | `LinkSafety`: web and mail links open; links to other apps ask first; `file:` links open documents only — apps, scripts, installers and shortcuts are revealed in Finder |
| Board IDs | Must be plain (`BoardIDSafety`) because they name the history file |
| Deep links | `localproductivity://` only navigates; paths must be inside the workspace and exist |
| Calendar access | `com.apple.security.personal-information.calendars` + usage description; full access requested only when connecting |
| Network | Outgoing connections only (Google, Microsoft, GitHub APIs) |
| Secrets | OAuth tokens and the GitHub token in the login Keychain; never in files, logs or Git |
| Client IDs | Public identifiers (no client secrets — PKCE) entered in Settings, stored in preferences |
| Shared data | Only board summaries (lists, titles, dates, tags, activity) — never notes |
| Signing | Hardened runtime with no exceptions; Release builds do not carry `get-task-allow` (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`) |
| Notifications | Content stays on the Mac; reminders show titles of the user's own tasks and events |

## 10. Testing and verification

| Layer | How |
|---|---|
| Markdown engine | `Scripts/test.sh markdown` — 355 checks: round trips, inline parsing, escaping, the paragraph cache, fuzzing (4,000 random documents keep their content; 3,000 realistic notes round-trip byte for byte) |
| Calendar mappings, OAuth | `Scripts/test.sh calendar` — 63 checks with recorded-style responses |
| Safety rules | `Scripts/test.sh safety` — 54 checks (paths, links, board IDs) |
| Widgets | `Scripts/test.sh widgets` — 18 checks (snapshot reading and storage, links) |
| Reminders | `Scripts/test.sh reminders` — 54 checks (time parsing, planning, limits, identifiers) |
| Boards | `Scripts/test.sh boards` — 137 checks (format round trips, edge cases, templates, diffing, lenient logs, reports, layout, drop targets, fuzzing 3,000 boards) |
| UI and behaviour | `Scripts/snapshot.sh` drives the real app (unsandboxed Debug build), runs scripted steps and saves window captures to `.build/shots/` |
| Speed | `Scripts/make-stress-vault.sh` + the harness's `perf-*` steps; `xcrun xctrace` with `--attach` for profiles |
| Widgets visually | `Scripts/render-widgets.sh` |
| Builds | `Scripts/build.sh` (sandboxed Debug), Xcode plugin `BuildProject`, Release via `Scripts/deploy.sh` |

## 11. Build, release and rollback

- One shared scheme, `Local Productivity`, builds the app and embeds the widget extension.
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set at project level for both targets.
- `LP_TEAM_ID=<team> Scripts/build.sh` / `Scripts/deploy.sh` sign with a team (needed for widget
  data); without it LP is signed ad hoc. `Scripts/signing-team.sh` lists available teams.
- `Scripts/deploy.sh <version> --confirmed` — only once the owner has confirmed the release (run
  by hand, it asks for the version to be typed instead): checks, tests, **backs up the current
  release first**, builds a Release, tags `v<version>`, pushes, and publishes a GitHub Release with
  the app and the user guide. The notes are the version's entry in `CHANGELOG.md`.
- `Scripts/make-user-guide.sh` — prints `docs/user-guide/guide.html` to `docs/LP User Guide.pdf`
  with WebKit, then adds page numbers, a linked contents page and bookmarks with Core Graphics.
- `Scripts/rollback.sh <version>` — downloads a previous release's app, or restores its source on
  a new branch.

See `CLAUDE.md` for the full rule and procedure.
