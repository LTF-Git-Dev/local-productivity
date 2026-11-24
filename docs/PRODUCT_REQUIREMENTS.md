# LP — Product Requirements

**LP (Local Productivity)** is a native macOS app that turns any folder of Markdown files into a
calm, Notion-style workspace for notes, tasks, calendars and boards — without taking the files
away from their owner.

| | |
|---|---|
| Owner | LTF |
| Platform | macOS 15 Sequoia or later (also 26 Tahoe and 27), Apple silicon and Intel; native SwiftUI + AppKit, with a WidgetKit extension |
| Current version | **1.0.2** (2026-11-25): LP with Claude; before it 1.0.1 (2026-11-23) and the first release, 1.0.0 (2026-11-18) |
| Repository | github.com/LTF-Git-Dev/local-productivity (private) |
| Status of this document | Living — update it whenever a feature ships, changes or is cut |

---

## 1. Problem

Obsidian proves that a folder of plain Markdown files is the right foundation for a personal
knowledge base: the notes are portable, durable and owned by the user. But its interface shows
Markdown syntax, feels like a developer tool, and is visually busy. Notion has the calm,
structured interface people enjoy, but keeps notes in its own cloud database.

## 2. Vision

> A beautiful, quiet place to think and plan, built directly on the user's own files.

- **Notion's structure with an Apple finish.** Minimal, generous, one accent colour; no visible
  Markdown syntax while writing.
- **The folder is the truth.** Every note, task and board is a plain `.md` file the user can open
  in Obsidian, a text editor, or Git. LP never locks anything in.
- **Everything in one window.** Notes, tasks, a calendar connected to real calendar accounts, and
  boards that track progress.

## 3. Users

| Persona | Needs |
|---|---|
| **The owner (primary)** — keeps a personal knowledge base in Markdown, already uses Obsidian, cares about design | Write comfortably, find anything fast, see the week, track projects, keep files portable |
| **A collaborator / stakeholder (secondary)** — does not use LP | See how a project is going from a link, on any device, without an account |

## 4. Principles (in priority order)

1. **Never damage the user's files.** Opening a note never changes it. Untouched text round-trips
   byte for byte. Unknown syntax is preserved verbatim. Deleting moves to the Trash.
2. **Visual quality is a requirement, not polish.** Every screen is reviewed in light, dark and a
   narrow window before it ships.
3. **Accessible by construction.** Text meets WCAG AA contrast; every action has a keyboard and
   VoiceOver path; motion follows Reduce Motion.
4. **Local first, private by default.** Data stays on the Mac. Anything that leaves it (calendar
   sync, a shared progress page) is explicit, opt-in and explained.
5. **Plain-file compatibility.** Formats follow existing conventions (CommonMark, Obsidian
   wiki links and callouts, Obsidian Tasks dates, Obsidian Kanban boards).

## 5. Functional requirements

Status: ✅ in 1.0.0 · 🟡 partly · ⬜ planned

### 5.1 Workspace

| ID | Requirement | Status |
|---|---|---|
| WS-1 | Choose any folder as the workspace; remember it across launches (security-scoped bookmark) | ✅ |
| WS-2 | Switch between recent workspaces | ✅ |
| WS-3 | Sidebar tree of folders and pages; create, rename (inline), move (drag), duplicate, trash | ✅ |
| WS-4 | Favourites and recently opened pages | ✅ |
| WS-5 | Reflect changes made by other apps immediately (file watching), including in the open page or board | ✅ |
| WS-6 | Back/forward navigation and restoring the last screen per workspace | ✅ |

### 5.2 Editor

| ID | Requirement | Status |
|---|---|---|
| ED-1 | WYSIWYG Markdown: headings, paragraphs, bold/italic/strike/highlight/code, links, lists, to-dos, quotes, callouts, code, dividers, images, tables | ✅ |
| ED-2 | Markdown typing shortcuts (`# `, `- `, `[] `, `**…**`) that convert as you type | ✅ |
| ED-3 | `/` block menu, `[[` page links, formatting bar on selection, block handle (add, turn into, move, duplicate, delete) | ✅ |
| ED-4 | Byte-for-byte preservation of untouched text; keep encoding, line endings, list numbering style | ✅ |
| ED-5 | Paste/drop images (stored in the workspace's attachments folder) and files | ✅ |
| ED-6 | Task due dates (`📅 YYYY-MM-DD`, optionally with a time: `📅 2026-11-20 14:30`) shown as chips coloured by urgency | ✅ |
| ED-7 | Edit tables in place (currently a sheet) | ⬜ |
| ED-8 | Update `[[links]]` when a page is renamed | ⬜ |
| ED-9 | Syntax colouring in code blocks | ⬜ |
| ED-10 | Text controls: any size from 12 to 24 pt (default 15), line spacing, page width (narrow → full), typeface (system, rounded, serif, mono or any installed family), live preview; ⌘+ / ⌘− / ⌘0 | ✅ |
| ED-11 | Interface size (small, default, large) for the sidebar, lists, boards, Home and the calendar | ✅ |

### 5.3 Home and search

| ID | Requirement | Status |
|---|---|---|
| HM-1 | Home: greeting, quick actions (new page, today's note, new board, search), recent pages, open tasks across the workspace | ✅ |
| HM-2 | Command palette (⌘K): pages by name, full-text search, actions | ✅ |
| HM-3 | Tick tasks off from Home and the calendar, including board cards | ✅ |

### 5.4 Calendar

| ID | Requirement | Status |
|---|---|---|
| CA-1 | Month view with daily notes, dated pages and due tasks; day panel | ✅ |
| CA-2 | Connect **Apple Calendar** (EventKit: iCloud, On My Mac, and any account in System Settings → Internet Accounts) | ✅ |
| CA-3 | Connect **Google Calendar** directly (OAuth 2.0 + PKCE, Calendar API v3) | ✅ (one click once Google approves LP — off until then, `googleAwaitingReview`; a client ID of your own or the Mac's Internet Accounts meanwhile) |
| CA-4 | Connect **Microsoft Outlook / Microsoft 365** directly (OAuth 2.0 + PKCE, Microsoft Graph) | ✅ (your own client ID for now; LP's own registration — one click — in the next update; work/school accounts may need admin approval) |
| CA-5 | **Read** events from all connected calendars, in each calendar's colour | ✅ |
| CA-6 | **Create, edit, move and delete** events; every change is written back to the source calendar | ✅ |
| CA-7 | Repeating events: change or delete one occurrence or the whole series | ✅ |
| CA-8 | Two-way freshness: sync on launch, on activation, every 5 minutes, on Apple change notifications, when browsing months, and after every edit; offline cache | ✅ |
| CA-9 | Show/hide individual calendars; read-only calendars are respected | ✅ |
| CA-10 | Conflict safety: version tags (etag/changeKey) prevent overwriting edits made elsewhere | ✅ |
| CA-11 | Week and agenda views | ⬜ |
| CA-12 | Invitees, attendees and recurrence editing (create a repeating event) | ⬜ |
| CA-13 | **Full sync** of Google and Outlook while online — a year back to two years ahead, about every half hour (and with the Sync button) — kept on the Mac until the account is disconnected, so the calendar works offline | ✅ (1.0.1) |
| CA-14 | When a service asks LP to slow down ("too many requests"), wait as long as asked (at most an hour) and say until when | ✅ (1.0.1) |

### 5.5 Boards (Trello-style)

| ID | Requirement | Status |
|---|---|---|
| BD-1 | Boards are Markdown files in the vault, in **Obsidian Kanban** format (`kanban-plugin: basic`) | ✅ |
| BD-2 | Lists (columns) and cards; add, rename, reorder, delete lists; "cards here count as done" lists | ✅ |
| BD-3 | **Drag cards** within and between lists; keyboard (Return, ⌘←/⌘→, Delete), menu and VoiceOver alternatives | ✅ |
| BD-4 | Card details: title, list, due date, tags, notes with checklists, archive, delete | ✅ |
| BD-5 | Every board change is undoable step by step | ✅ |
| BD-6 | **Tracking**: an activity log of cards added, moved, completed, reopened, renamed, re-dated, archived and deleted — including changes made in other apps while LP was closed | ✅ |
| BD-7 | **Progress**: percent done, cards per list, overdue, due soon, done this week, average time to done, trend over time (with table view), recent activity | ✅ |
| BD-8 | Stored **locally in the vault** (`.lp/boards/<board-id>.json` for history) | ✅ |
| BD-9 | **Share progress** as a live, read-only page anyone with the link can open from anywhere (a Google Doc in your own Drive, or a secret GitHub Gist; kept up to date automatically); card notes are never shared | ✅ |
| BD-10 | Export a self-contained HTML progress report | ✅ |
| BD-11 | Board cards with due dates appear on Home and in the calendar | ✅ |
| BD-12 | **Boards overview**: every board with its progress, lists, overdue and due-soon counts; sort; rename, reveal, trash | ✅ |
| BD-13 | Sharing options beyond GitHub | ◐ Google Drive (1.0.1). OneDrive needs access to all of a person's files and shows plain text; iCloud has no API for public links — not planned |
| BD-14 | **New boards from templates** (Simple, Project, Weekly, Content, Bugs) with a name and folder — one board per project | ✅ |
| BD-15 | Lists resize with the window; the progress panel sits beside the lists or floats when narrow | ✅ |
| BD-16 | Card assignees, covers and attachments | ⬜ |
| BD-17 | **A board keeps its identity**: renaming or moving it (in LP or elsewhere) keeps its history and sharing; copies (duplicated in LP, or copied in Finder or Obsidian) get their own, so nothing on a copy reaches the original's history or shared page | ✅ 1.0.1 (built on `feature/codex-review`) |
| BD-18 | **Only this Mac's shared pages are updated**: a share record found in the folder (from another Mac, LP 1.0.0, or whoever the folder came from) changes nothing until the person chooses *Keep It Updated From Here* | ✅ 1.0.1 (built on `feature/codex-review`) |

### 5.6 Reminders and notifications

| ID | Requirement | Status |
|---|---|---|
| NT-1 | A reminder on the day each open task or board card is due — at its own time (`📅 date 14:30`, `@@{14:00}`) or a chosen default (9:00) | ✅ |
| NT-2 | Reminder buttons: **Mark as Done** (ticks the box in the file), **Remind Me in an Hour**, **Remind Me Tomorrow**; tapping opens the page or board | ✅ |
| NT-3 | Alerts before timed calendar events (off, at start, 5–60 minutes); Apple Calendar events only when asked (Calendar already alerts for them) | ✅ |
| NT-4 | A morning summary of what is due, overdue and on the calendar; skipped on empty days | ✅ |
| NT-5 | Reminders arrive while LP is closed; planned a week ahead within macOS's 64-notification limit | ✅ |
| NT-6 | Settings → Notifications: an on/off switch for all reminders (off cancels everything waiting), permission state, options, and the reminders actually waiting | ✅ |

### 5.7 Widgets

| ID | Requirement | Status |
|---|---|---|
| WG-1 | **Today** widget (small, medium, large): date, due and overdue counts, items due, events left, tomorrow when there is room | ✅ |
| WG-2 | **Board** widget (small, medium): a chosen board's progress, overdue cards and lists | ✅ |
| WG-3 | Tapping a widget opens LP at Home, the day, the page or the board | ✅ |
| WG-4 | Widgets show live data when LP is signed with a team (a free Apple ID works); otherwise they explain how to set them up | 🟡 (needs the user's team) |

### 5.8 Settings

| ID | Requirement | Status |
|---|---|---|
| ST-1 | General (theme, daily notes folder, workspace), Editor (font, size, line spacing, width, interface size, spelling) | ✅ |
| ST-2 | Calendars: connect/disconnect accounts (one click once Google approves LP; your own client ID as Advanced, with guided setup), add accounts through the Mac's Internet Accounts, show/hide calendars | ✅ (1.0.1) |
| ST-3 | Sharing: connect a GitHub token (verified before saving, stored in the Keychain) | ✅ |
| ST-4 | Sharing: allow Google Drive for a connected Google account (`drive.file` only; asked when wanted); disconnecting deletes LP's Docs first | ✅ (1.0.1) |
| ST-4 | Notifications (see 5.6) | ✅ |
| AI-1 | **LP for Claude (MCP):** Claude Code and the Claude desktop app can read, write and update pages, tasks and boards (15 tools), on the Mac only, nothing deleted, every edit based on what it read | ✅ 1.0.2 (the person picks the workspace in a form each session; set up in Settings → Claude) |
| ST-5 | Updates: LP checks its GitHub Releases once a day (can be turned off; betas optional), shows what's new and installs with one click (Install and Restart); only updates signed with LP's release key, the download checked byte for byte; LP → Check for Updates… | ✅ (1.0.1) |

## 6. Non-functional requirements

| Area | Requirement |
|---|---|
| **File fidelity** | No change to a file unless the user edits it (renaming, moving or sharing a board adds only its `lp-board` ID line). Round-trip tests must stay at 0 failures. |
| **No lost work** | Edits are never dropped: a save that fails keeps them as a copy in LP's Recovered folder (outside the workspace) and says where; another app's version is kept as a copy before LP writes over it; a page or board LP can't read is never written; leaving, switching workspace and quitting wait until edits are saved or kept. |
| **Privacy & security** | Local-first: no servers, accounts, analytics or telemetry. Sandboxed app with access only to the chosen folder. Tokens in the Keychain, never in files or logs. OAuth with PKCE in a private sign-in window; LP never sees passwords. Connected services get the least privilege that works and only the fields LP shows; disconnecting revokes access where the service allows it. Policies: `PRIVACY.md`, `TERMS.md`, `COOKIES.md`, `docs/CONNECTED_ACCOUNTS.md`, `SECURITY.md`. |
| **Licence** | Open source under the MIT License (`LICENSE`), © 2026 LTF-Git-Dev; one public repository since 2026-11-23 (`github.com/LTF-Git-Dev/local-productivity`). |
| **Accessibility** | WCAG 2.2 AA: text contrast ≥ 4.5:1 in both modes; pointer targets ≥ 24pt; every icon-only control labelled; keyboard path for every action; Reduce Motion respected. Statement and the latest pass: `ACCESSIBILITY.md`. |
| **Performance** | Opening a page < 100 ms for typical notes; typing never blocks on disk; indexing runs in the background; calendar fills from cache immediately. Measured for 1.0.0 on a 3,132-note workspace: normal note opens in 33–100 ms and saves in ~5 ms; a 2 MB note saves in ~0.5 s; search 20–30 ms; full index 2.7 s. |
| **Reliability** | Atomic file writes; saves on deactivation and quit; recover gracefully when files change underneath. Parsers fuzz-tested (Markdown: 7,000 documents; boards: 3,000) — no crash, no lost text; board history read leniently. |
| **Compatibility** | macOS 15 and later. The same folder keeps working in Obsidian (wiki links, callouts, Tasks dates, Kanban boards and times). |
| **Security** | Note content cannot reach outside the workspace (paths, also through linked folders) or run code (links open documents only, anything runnable is revealed in Finder; other apps' links ask first). Deep links only navigate. Data in a workspace's `.lp/` folder is never trusted to publish, delete or open anything (one decision, `ShareTrust`, pinned by the `ownership` tests: someone else's copy of a folder can't change your shared page). Reminders act only in their own workspace. Services' rate limits are honoured. Release builds carry no debugging entitlement, and a published app never shows a personal email in its signature or contains a token. Before every version is finalized, the owner's security checklist is run and its result recorded (`docs/SECURITY_CHECKLIST.md`). |
| **Releases** | Every finished task is reviewed by a second agent (Codex), checked against the security checklist and tested again; nothing is released until the owner confirms it. **Every version is a beta first** (a GitHub pre-release for testing) and becomes official only after the owner has tested it and confirmed it works — exactly the code that was tested. Every release is tagged and published with its app and the user guide; the release it replaces is backed up first, so any version can be restored (see `docs/RELEASING.md`). |

## 7. Out of scope (for now)

- Real-time multi-user editing.
- A mobile app.
- Hosting notes on LP-owned servers.
- Plugins/extensions.

## 8. Success measures

- The owner uses LP daily instead of Obsidian for writing and planning.
- Zero data-loss reports; all fidelity tests green on every release.
- Every screen passes the design review checklist in `docs/DESIGN_SYSTEM.md`.

## 9. Roadmap

1. **Shipped in 1.0.0 (2026-11-18), the first release:** everything marked ✅ above — the editor,
   Home and search, the calendar with Apple, Google and Microsoft sync, boards with tracking,
   sharing and templates, reminders, widgets, text controls, macOS 15–27 — and the user guide.
2. **Shipped in 1.0.2 (2026-11-25):** LP with Claude (MCP) — Claude Code and the Claude desktop app read, write and update pages, tasks and boards in the workspace the person picks.
3. **Shipped in 1.0.1 (2026-11-23):** in-app updates, Google Drive sharing, full calendar sync, least-privilege permissions, the
   new icon, the open-source licence and policies, and the fixes from Codex's reviews. Then, once
   Google approves LP: one-click Google Connect (a small update through the in-app updater).
   Microsoft one-click when LP can register with Microsoft.
3. **1.1:** backlinks and an outline for the open page; update links on rename; week view.
4. **Then:** in-place tables; code syntax colouring; card assignees; page templates.
5. **Later:** iCloud-based sharing; quick capture from the menu bar; interactive widgets.

## 10. Open questions

- Should shared progress pages support a custom domain or password?
- Should board history (`.lp/`) be excluded from sync services by default?
- Is a menu-bar quick-capture window worth the extra surface?
