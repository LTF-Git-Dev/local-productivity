# Changelog

What changed in LP, newest first. Every released version is a tag and a GitHub Release with its
app; its entry here becomes the release notes, and `Scripts/rollback.sh` restores any of them.

Each working session adds a dated line under **Unreleased** — what changed, on which branch, and
whether it was released. When the owner confirms a release, those lines move under the new
version's heading (`## <version> — <date>`), which `Scripts/deploy.sh` reads.

## Unreleased

Nothing yet.

## 1.0.0 — 2026-11-18

The first release of LP: a calm, native macOS home for your notes, tasks, calendar and projects,
built on a folder of plain Markdown files. For macOS 15 Sequoia and later, on Apple silicon and
Intel. New to LP? Start with the user guide attached to this release (also in the repository as
`docs/LP User Guide.pdf`).

**Notes**
- Any folder is a workspace — an Obsidian vault works as it is.
- Write without seeing Markdown: headings, lists, to-dos, quotes, callouts, code, tables, dividers
  and images look finished while you type. `/` opens the block menu, `[[` links a page, a
  formatting bar appears over a selection, and every block has a handle to move or change it.
- To-dos with due dates and times (`📅 2026-11-20 14:30`), shown as chips coloured by urgency.
- Your files stay exactly as they were unless you edit them, and changes made in other apps show
  up straight away.

**Finding your way**
- Home with quick actions, recent pages and every open task; search (⌘K); today's note (⌘T);
  favourites; folders you can rename, move, duplicate and trash.

**Calendar**
- A month view with your daily notes and due tasks, in two-way sync with Apple Calendar, Google
  Calendar and Microsoft Outlook. Add, change and delete events, including repeating ones.

**Boards**
- Trello-style boards — one per project — stored as Obsidian Kanban files, with an overview of
  every board and templates for new ones.
- Drag cards or move them from the keyboard; card details with due dates, reminder times, tags and
  checklists; undo for every change.
- Progress tracking with a full history, shared as a live read-only page anyone with the link can
  open, or exported as a report.

**Reminders and widgets**
- Reminders when tasks and cards are due (at their own time), alerts before events and a morning
  summary — even when LP is closed — with Mark as Done and snooze buttons.
- Today and Board widgets for the desktop (they need LP signed with your Apple ID team once; the
  guide explains how).

**Make it yours**
- Text size from 12 to 24 points, line spacing, page width, typeface and interface size; light
  and dark.

**Quality**
- Sandboxed and hardened; nothing in a note can reach outside your workspace or run code.
- Quick with large workspaces: in a 3,000-note workspace pages open in under 100 ms and search
  takes about 25 ms.
- 681 automated checks, including fuzzing thousands of notes and boards for lost text.

## Before 1.0.0

On 17 and 18 November 2026, test builds were published as 1.0.0 and 1.1.0. They were withdrawn on
18 November, when LP was released afresh as 1.0.0. Their code is still in the history — the old
1.0.0 at `b25bae0`, the old 1.1.0 at `7a2ed22` — and their apps are kept outside the repository.
