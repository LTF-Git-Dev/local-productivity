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
  and Finder tags. Every path LP creates or moves to goes through `PathSafety.contained`, and
  `PathSafety.resolvesInside` (the nearest existing folder, with links resolved) keeps writes from
  leaving the workspace through a folder that is a link elsewhere.
- **Tasks:** `PageTasks` (Foundation-only, tested) decides which to-dos are tasks and finds one
  again to tick it off from Home, a reminder or a widget: at its place if it is still the same
  task (wording, due date and time, state), otherwise only a unique match — never a guess.

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
- **Never losing work.** Before writing, `checkBeforeWriting()` compares the file with what LP
  last read: if another app changed it, that version is kept as a copy first and the person is
  told; a file that is gone or unreadable is never written. A page that couldn't be read opens
  read-only (`readFailure`, with Try Again). Leaving a page, switching or closing the workspace,
  trashing and quitting (`AppDelegate.applicationShouldTerminate` → `readyToQuit()`) go ahead only
  once the edits are saved or kept: `closeSavingChanges()` puts unsaved text in
  `Application Support/LP/Recovered` (`RecoveredCopies`, never the workspace) and the alert offers
  Show in Finder. If neither works, the page stays open.

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

1. Every change goes through `perform(_:undoManager:change:)`: first take in any change made
   elsewhere (`catchUpWithDisk`, which also clears undo when the file changed), then mutate a
   copy and **write the file first** — the board on screen, its history and its shared page are
   updated only if that worked. A board that can't be read (or isn't UTF-8) is read-only.
2. `BoardDiff.events(from:to:)` compares old and new boards by card ID → `BoardEvent`s.
3. The activity log `.lp/boards/<board-id>.json` (`BoardActivityLog`) holds events, daily
   snapshots (total/done), first-seen dates, the share record, `lastSeen`, and the file it
   belongs to (`path`, `fileHasID`). It is decoded leniently: a part another version wrote that
   cannot be read is skipped, never the whole log.
4. External edits (`reloadFromDisk`) are diffed and recorded the same way. List IDs are kept
   across reads when a list's title is unique, so actions aimed at a list still find it. If the
   file now holds another board (its ID changed and `historyID` agrees), the store switches to
   that board's history and sharing instead; the card sheet remembers the board it opened on and
   refuses to change anything after such a switch (`isStill`).
5. One rule decides which files are boards, on bytes: `BoardParser.isBoard(head:)` — starts with
   `---` and names the plugin within the first 1 KB — for opening, the index, duplicating and
   moving alike, `.md` and `.markdown`.

**Identity** — a board's history and sharing go by its board ID. `BoardStore.historyID` is the
one rule for which ID that is, used when a board opens and before it moves:

- The `lp-board` in its file — unless the file is a **copy** made outside LP (Finder, Obsidian):
  the history belongs to another board file with the same ID (or, for a 1.0.0 history without a
  path, an older board file has it). A copy goes by an ID of its own that no history uses
  (`ownID`), written into its file the first time LP saves, shares or moves it; until then no
  history is written for it (`saveLog`), so it can't collide with anything.
- A board LP has never saved goes by an ID made from its path (`derivedID`, FNV-1a) — unless the
  history under that ID is another file's: written while its file carried the ID
  (`fileHasID`), recorded for another path, or (1.0.0) its ID is in another board file — or this
  Mac has a sharing grant for that ID (sharing writes the ID into the file first, and an older LP
  can drop the history's ownership fields). Then it, too, gets its own ID.
- Before LP renames or moves boards (or a folder), `Workspace.persistBoardIdentities` reads the
  files under the path as they are now — checking every one before writing anything — and writes
  each board's ID into its front matter if it isn't there (`BoardParser.settingFrontMatter` — the
  rest of the file stays byte for byte), re-reading each just before so a board changed meanwhile
  stops the move. If any can't be read or written, nothing is moved. Each board's history is then told its new place
  *before* the move (`Workspace.moveWithBoards`, `BoardStore.setHistoryOwner`) — a history LP
  can't update (outside the workspace, read-only) stops the move — and put back if the move
  fails. Duplicates made in LP get fresh random IDs.

**UI** — `BoardView` lays lists out with `BoardLayout`: lists share the width between 260 and
340 pt; past that the row scrolls. The progress panel sits beside the lists from 960 pt and
floats over them below. Dragging is in-app (`DragGesture` + frame preferences: `BoardCardDrag`,
`BoardDropTarget.find`) so one code path works on macOS 15–27 and synthetic events can test it;
text dragged in from other apps becomes new cards. `BoardsView` shows every board as a card and
hosts `NewBoardSheet`.

**Sharing** — always through the person's own accounts, behind one door, `SharingServices`:
**GitHub** — `BoardReport.markdown` as a **secret** gist (`GistPublisher`, the user's token in the
Keychain); **Google Drive** — `BoardReport.documentHTML` uploaded and turned into a Google Doc that
anyone with the link can read (`GoogleDriveMapping` → `GoogleDrivePublisher`, through the connected
Google account's own `AuthorizedClient`, via its `DriveBackend`), with only the `drive.file`
permission, asked for when the person allows Drive (`GoogleCalendarMapping.configuration(includeDrive:)`,
`OAuthTokens.scopes` records what was granted). `BoardShare` carries the service, the page ID and,
for Drive, the account; a gist is saved exactly as before. The Drive pages LP made are listed per
account in preferences (`DrivePageRegistry`) — a page from the moment it is uploaded, before it is made public, and a page this Mac adopted ("Keep It Updated From Here") or is about to update — so disconnecting an account deletes them first: `SharingServices.disconnect` holds back new Drive work for the account (`DriveWork`), waits for what is on its way, deletes, then disconnects
(Settings → Calendars). Updates are debounced (4 s) after changes.
`BoardReport.html` produces the exported report. Card notes are never included.

The share record in `.lp/` could have been written by anyone who handed over the folder, so it
never authorizes anything. This Mac keeps its own list of pages it may update — per workspace,
in preferences (`workspace.shares.<id>`), keyed by board file path, board ID and gist ID — filled
when it publishes, or when the person chooses **Keep It Updated From Here**; both write the
board's ID into its file first. `BoardStore.shareIsTrusted` requires that grant and the ID in the
file; anything else is shown as *set up elsewhere* and never updated or deleted. LP's renames and
moves carry grants along (`rebaseShares`). The page's link is built from the gist ID
(`BoardShare.pageURL`, `https://gist.github.com/<id>`), never taken from the record, and gist IDs
must be letters and digits (`BoardShare.isValidGistID`) before they reach an API path.

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
  Microsoft uses the `msauth.<bundle id>://auth` redirect. A new sign-in goes to the person's own
  client ID if they set one, else LP's (`AppRegistration.clientID`, `BuiltInRegistration`) — except Google's while
  `googleAwaitingReview` is set (until Google approves LP: `effectiveGoogleClientID` refuses it, even
  pasted as one's own, and "Allow Google Drive…" refuses accounts that use it); tokens
  remember the registration that issued them (`OAuthTokens.clientID`), and refreshes and
  reconnecting at launch use that one (`OAuthTokenStore.storedClientID`).
- **Mapping** (`GoogleCalendarMapping.swift`, `MicrosoftGraphMapping.swift`): pure translation of
  URLs, responses and request bodies — covered by 63 tests.
- **Sync** (`CalendarSyncStore.swift`): a **full sync** of each account — a year back to two years
  ahead (`CalendarSyncRange`), plus the months shown — for Google and Outlook accounts that have
  none from the last 30 minutes (checked every 5 minutes, also while LP is in the background), and
  after the Sync button, a new connection, a calendar shown or hidden, and every successful
  change (`requestFullSync` clears the account's mark, so failures are retried in full, counts
  the request so what a pass under way fetched for that account is dropped rather than merged,
  and queues another pass). While a change is on its way through a connection (`pendingWrites`,
  by connection), what a pass brings back through it isn't used either; when a change finishes,
  however it went, the account's current connection syncs in full; a confirmed delete removes
  the event again. Apple Calendar keeps the small windows (EventKit reads are
  synchronous, and macOS has it all anyway). The refreshes in between
  (launch, activation, every 5 minutes, `EKEventStoreChanged`, after edits) fetch the months shown
  and the weeks around today. Fetched events replace only the times fetched (`SyncEvent.merging`),
  so everything synced stays until the account is disconnected. Caches to
  `~/Library/Containers/…/Application Support/LP/calendar-cache.json`; edits apply optimistically
  and roll back if the provider refuses. `onEventsChanged` triggers a glance update.
- **"Too many requests":** `RateLimit.retryDate` (in `OAuthCore.swift`, tested) reads a service's
  answer — a 429; a 403 with `Retry-After`, a used-up allowance, Google's `rateLimitExceeded` or
  GitHub's "secondary rate limit" message; a 503 with `Retry-After` — into the time LP may call
  again (one minute if none is given, never more than an hour). `ServicePause` keeps that time per
  calendar account (`OAuthTokenStore.pauseKey`; a sign-in still finding its account has a key of
  its own, from its credential's fingerprint) and per GitHub token; a later answer with a shorter
  wait never shortens it. `AuthorizedClient` checks it right before every network call — again
  after waiting for a token — and so does the token refresh, whose own "slow down" counts too:
  pages of a sync under way and changes alike throw `CalendarSyncError.rateLimited`; passes skip the account
  (`provider.pausedUntil`) and show the message, and the timer or the Sync button syncs it
  afterwards.
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
| Board IDs | Must be plain (`BoardIDSafety`) because they name the history file; history is written only inside the workspace |
| Shared pages | Only pages this Mac published or was allowed to keep up to date are updated or deleted — one decision, `ShareTrust.isTrusted` (the record from the folder counts only with this Mac's grant for that file, board and page — a Drive page's grant names its account too), pinned by the `ownership` suite; links are built from validated gist IDs on github.com. While GitHub asks LP to slow down, nothing is sent to it (`GistPublisher.pausedUntil`), and automatic updates catch up afterwards |
| Reminders | Carry their workspace; acting on one never touches a matching task in another workspace |
| Deep links | `localproductivity://` only navigates; paths must be inside the workspace and exist |
| Calendar access | `com.apple.security.personal-information.calendars` + usage description; full access requested only when connecting. Apple Calendar events are read from EventKit and not copied into LP's cache |
| Connected accounts | Least privilege, pinned by the calendar tests: Google `calendar.calendarlist.readonly` + `calendar.events`; Microsoft `Calendars.ReadWrite` + `offline_access` (no profile — the account comes from the default calendar's owner). Only the event fields LP shows are requested (`fields=` / `$select`) — except Microsoft's create request, which has no field mask, so the whole new event comes back and LP keeps only the fields it needs. Sign-in asks for a private `ASWebAuthenticationSession` (`prefersEphemeralWebBrowserSession`; Safari honours it). `OAuthTokenStore.forget()` only forgets locally (also used when a sign-in's probe store hands its tokens on); `disconnect()` also revokes at Google (`OAuthRequests.revocation`), and `OAuthRevocations` makes a sign-in with the same registration wait for a pending revocation, since Google ends the whole grant. See `docs/CONNECTED_ACCOUNTS.md` |
| Network | Outgoing connections only (Google, Microsoft, GitHub APIs); no analytics, telemetry or servers of ours |
| Secrets | OAuth tokens and the GitHub token in the login Keychain; never in files, logs or Git |
| Client IDs | Public identifiers (no client secrets — PKCE): LP's own (`BuiltInRegistration`, see `docs/REGISTERING_LP.md`) or the person's own, entered in Settings (Advanced) and stored in preferences; tokens remember which issued them |
| Shared data | Only board summaries (lists, titles, dates, tags, activity) — never notes |
| Signing | Hardened runtime with no exceptions; Release builds do not carry `get-task-allow` (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`) |
| Notifications | Content stays on the Mac; reminders show titles of the user's own tasks and events |
| Published apps | `deploy.sh` refuses an app whose code signature shows an email address, or that contains anything shaped like a token or private key; harness code and switches are compiled out of Release, and harness runs never read the real GitHub token |
| The checklist | The owner's security checklist — secrets, ownership, database rules, mass assignment, payments, rate limits, prove it — is run before every version is finalized; what each point means for LP and the result per version are in `docs/SECURITY_CHECKLIST.md` |

## 10. Testing and verification

| Layer | How |
|---|---|
| Markdown engine | `Scripts/test.sh markdown` — 365 checks: round trips, inline parsing, escaping, the paragraph cache, fuzzing (4,000 random documents keep their content; 3,000 realistic notes round-trip byte for byte) |
| Calendar mappings, OAuth | `Scripts/test.sh calendar` — 128 checks with recorded-style responses, the permissions, fields and revocation LP asks for, full-sync merging, and "slow down" answers |
| Safety rules | `Scripts/test.sh safety` — 63 checks (paths, links through symlinks, board IDs, sharing grant keys) |
| Widgets | `Scripts/test.sh widgets` — 18 checks (snapshot reading and storage, links) |
| Reminders | `Scripts/test.sh reminders` — 62 checks (time parsing, planning, limits, identifiers, workspaces, boards) |
| Tasks | `Scripts/test.sh tasks` — 24 checks (which to-dos are tasks; finding the right one to tick off after the page changed) |
| Boards | `Scripts/test.sh boards` — 220 checks (format round trips, edge cases, templates, diffing, lenient logs, reports, layout, drop targets, moving cards, card edits, list IDs, front matter, gist links, Drive requests and records, fuzzing 3,000 boards) |
| Who may change what | `Scripts/test.sh ownership` — 29 checks: person B (a copy of A's folder, a folder handed over, a web link, a forged sign-in reply) can't change what is A's; `LP_TEST_VERBOSE=1` prints each one |
| UI and behaviour | `Scripts/snapshot.sh` drives the real app (unsandboxed Debug build), runs scripted steps and saves window captures to `.build/shots/` |
| Speed | `Scripts/make-stress-vault.sh` + the harness's `perf-*` steps; `xcrun xctrace` with `--attach` for profiles |
| Widgets visually | `Scripts/render-widgets.sh` |
| Builds | `Scripts/build.sh` (sandboxed Debug), Xcode plugin `BuildProject`, Release via `Scripts/deploy.sh` |

## 10b. LP for Claude (MCP)

`lp-mcp` (`MCP/`) is a separate command-line program: an MCP server over stdio (JSON-RPC 2.0, one
message per line) that Claude Code or the Claude desktop app starts with `--workspace <folder>`. It
compiles LP's Foundation-only code (`App/Day.swift`, `Markdown/`, `Workspace/PageTasks.swift`,
`Workspace/Safety.swift`, `Boards/Model/`), so pages, tasks and boards are read and written exactly as
the app does; it shares no state with the app, which picks up its changes like any other editor's.

- **Files** (`AnchoredFiles`): one open handle on the workspace; every path walked from it with
  `openat(O_NOFOLLOW)`; regular, non-hidden files only; reads capped at 4 MB; new pages written
  under a hidden name then renamed exclusively; edits written beside the page and swapped in with
  `renameatx_np(RENAME_SWAP)`, then the swapped-out version (content and metadata) compared with
  what was read — a save made meanwhile is swapped back and the edit redone on top. Owner, group,
  mode, flags, ACL, extended attributes and creation date are carried over or the edit is refused.
- **Operations** (`LPVault`): 15 tools; edits of existing content need the page or board revision
  (SHA-256 prefix) they read, and every change returns the new one; boards change only card by
  card through `BoardParser`/`CardEdit`/`moveCards`; nothing is deleted.
- **Shipped inside LP.app** (1.0.2): the `lp-mcp` tool target (shared Foundation-only sources plus `MCP/`,
  no sandbox, hardened runtime) is copied to `LP.app/Contents/Helpers/lp-mcp` and signed with the app, so
  the in-app updater keeps it current. Settings → General → LP with Claude shows four numbered
  steps, each with one short command and a Copy button (`ClaudeSetup`, shell-quoted, tested in `safety`):
  clear the download quarantine on the helper (macOS otherwise refuses to run it), `claude mcp add
  --scope user lp …`, `claude mcp get lp`, then a new Claude Code session.
- **Tests**: the `mcp` suite drives `MCPServer.handle` directly; real clients are tried with a
  one-off `--mcp-config` (docs/MCP.md, "For maintainers").

## 11. Build, release and rollback

- **In-app updates.** `Updater` (app, sandboxed) reads LP's GitHub Releases (public API, no
  account; User-Agent carries only LP's version) once a day if allowed and on LP → Check for
  Updates…, picks the newest release the person may get (`UpdatePolicy`: betas only with
  "Include beta versions"; tag and pre-release mark must agree), and accepts it only if its
  `update.json` is signed by a key in `UpdateFeed.publicKeys` (`UpdateSignature`, Ed25519) and is
  newer by (version, build). Install and Restart downloads the zip, checks size and SHA-256, and
  hands it to **LPUpdateInstaller** (an unsandboxed XPC service in `Contents/XPCServices`, code
  requirement: LP's identifier). The helper re-verifies everything itself, copies the zip into a
  private folder on the app's volume before hashing, unpacks it (`ditto --noqtn`), requires one
  `LP.app` with LP's bundle ID, the signed version and build and a valid code signature
  (`SecStaticCodeCheckValidity`, strict, nested), removes the quarantine flag and swaps it in with
  `replaceItemAt` (keeping the app's place and name). LP then starts the new copy first
  (`-LPRelaunchAfter <pid>`: before any of its state exists it waits up to two minutes for this
  one to end, and leaves if it doesn't) and quits the usual way (`applicationShouldTerminate`,
  which saves or keeps every edit). If that quit is cancelled, this LP keeps running normally and
  says the update starts next time; the waiting copy gives up. The helper reads both apps'
  `Info.plist` from disk each time (Bundle caches it) and refuses anything not newer than the
  installed app. Downloads stop on URLSession's own queue the moment they pass the signed size. A translocated copy (opened from Downloads) or a folder the user can't write
  is refused with what to do.
- **Release signing.** `Scripts/release-key.swift` keeps the Ed25519 key in the owner's login
  Keychain ("LP release signing key"); `deploy.sh` writes `update.json` (bundle ID, tag, version,
  build, pre-release, zip name, size, SHA-256, minimum macOS) from the zip's own app, signs it and
  uploads `update.json` + `update.json.sig` with every release. Each build gets a build number
  (UTC minutes); the official release reuses its beta's app and so its build.

- One shared scheme, `Local Productivity`, builds the app and embeds the widget extension.
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set at project level for both targets.
- `LP_TEAM_ID=<team> Scripts/build.sh` / `Scripts/deploy.sh` sign with a team (needed for widget
  data); without it LP is signed ad hoc. `Scripts/signing-team.sh` lists available teams.
- **Every version is a beta first** (`docs/RELEASING.md`). `Scripts/deploy.sh <x.y.z>-beta.<n>
  --confirmed` — only once the owner said yes to the beta: checks (on its branch, pushed), tests,
  **backs up the current official release first**, builds a Release, checks what is in it (no
  email in the signature, nothing shaped like a token or key), tags `v<x.y.z>-beta.<n>`, pushes the
  branch and the tag, and publishes a GitHub **pre-release** (never Latest) with the app and the
  user guide. `main` is not touched.
- `Scripts/deploy.sh <x.y.z> --confirmed` — only once the owner confirmed the beta works and its
  branch was merged into `main`: the same steps from `main`, refused unless a beta of the version
  is published and the app's files are exactly the newest beta's; published as **Latest**. Run by
  hand without `--confirmed`, either asks for the version to be typed. The notes are the version's
  entry in `CHANGELOG.md`.
- `Scripts/make-user-guide.sh` — prints `docs/user-guide/guide.html` to `docs/LP User Guide.pdf`
  with WebKit, then adds page numbers, a linked contents page and bookmarks with Core Graphics.
- `Scripts/rollback.sh <version>` — downloads a previous release's app, or restores its source on
  a new branch.
- Before a release is proposed, the Codex agent reviews the work through Herdr, everything is
  tested again (rule 3 in `CLAUDE.md`), and the security checklist is run (rule 4).

See `CLAUDE.md` for the full rule and procedure.
