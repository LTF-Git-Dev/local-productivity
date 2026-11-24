# LP for Claude (MCP)

`lp-mcp` lets Claude — **Claude Code** and the **Claude desktop app** — read and change your LP
workspace: pages, tasks and boards. It's a small program that works on the workspace folder
directly, with LP's own code, so files stay exactly as LP and Obsidian write them. LP doesn't need
to be open; when it is, it shows Claude's changes as they happen.

It runs on your Mac only. Nothing goes to LP's makers; what Claude reads goes to Claude, as with
anything you share in a conversation.

## You choose, every time

You give `lp-mcp` the workspaces Claude may ever use (one or more `--workspace` folders) — it can
reach nothing else. In each Claude Code session (each time the LP server starts — the desktop app
may share one between chats: see Known limits), **before Claude can read or change anything, LP itself
asks you** — a small form in Claude Code — which of those workspaces it may use, and optionally one
folder inside it (leave the folder empty to allow the whole workspace). Only your answer counts:
Claude can't fill in the form, and if you decline or close it, nothing is chosen and every tool
keeps refusing. With a folder chosen, nothing outside it can be read or changed. Claude sees nothing
about your workspaces — not even their names — until you've chosen. To switch, Claude asks again
and you get the form again.

Claude apps that can't show such forms are refused. Only if you start `lp-mcp` with
`--allow-choice-in-chat` will it instead accept the workspace Claude passes on from your chat —
weaker, because then Claude, not LP, reports your choice.

## What Claude can do

| Read | Write | Update |
|---|---|---|
| `lp_list_workspaces` — the workspaces allowed, and their folders | `lp_use_workspace` — the workspace (and folder) you chose | |
| `lp_list_pages` — every page and board | `lp_create_page` — a new page (never replaces one) | `lp_replace_text` — change one exact passage of a page |
| `lp_search` — by name and text, like ⌘K | `lp_append_to_page` — add to the end of a page | `lp_update_page` — rewrite a page (only the version it read) |
| `lp_read_page` — a page's Markdown | `lp_daily_note` — today's (or any day's) note, created if needed | `lp_set_task_done` — tick a task off or reopen it |
| `lp_list_tasks` — open/done tasks, soonest due first | `lp_create_board` — a board from LP's templates | `lp_update_card` — edit a card or move it to another list |
| `lp_list_boards` — every board's progress | `lp_add_card` — a card on a board | |
| `lp_read_board` — a board's lists and cards | | |

Ask things like *"What's overdue?"*, *"Add 'call the printer, due Friday' to my Launch board"*, *"Put
today's standup notes in my daily note"*, *"Move the press release card to Review"*.

## Safety

- Only regular `.md` and `.markdown` files **inside the workspace folder**: no `..`, absolute
  paths, hidden folders (`.lp`, `.obsidian`, `.git`), links of any kind, pipes or devices. Every
  path is walked from the workspace folder itself, one folder at a time, so a folder swapped for a
  link can't redirect a read or a write.
- **No file is ever deleted**, and a new page never replaces a file ("Plan 2" when "Plan" exists).
  Claude can still change or remove the text inside a page — rewriting a page needs the version it read.
- Files that aren't UTF-8 text, larger than 4 MB, read-only or locked are left alone, and nothing
  is written that would pass 4 MB.
- **Boards change card by card only**, through LP's board code, so they stay valid Kanban boards;
  tags and titles can't inject lists or cards.
- **A save made meanwhile isn't overwritten.** The new version is written beside the file and
  swapped in, in one step, and only over the version that was read: if LP, Obsidian or another
  editor saved in between, its version is swapped back and the change is made again on top of it;
  if two saves land in that moment, the extra one is kept next to the page as "… (conflict).md".
  (Not covered: a program writing into the file it opened earlier, in place — for example Vim set
  to `backupcopy=yes` — at the very moment Claude saves; LP and Obsidian save whole files.) Finder
  tags and
  permissions stay — or the edit isn't made — and so does the creation date where the disk keeps one.
  New pages are written in full under a hidden name first, so a failed write never leaves half a page.
- Changes to what's already there need the **revision** they were based on — rewriting a page
  (`lp_update_page`), adding or changing a card (`lp_add_card`, `lp_update_card`) and ticking a
  task off (`lp_set_task_done`) — so Claude can't act on something that changed after it read it.
  Every change returns the new revision for the next step.
- Results say when they're `incomplete` (a folder or page that couldn't be read, or more than
  20,000 pages); a daily note is then never created twice.
- In Claude, every tool except the six reading ones asks for your approval unless you allow it;
  the three that can replace text (`lp_update_page`, `lp_replace_text`, `lp_update_card`) are
  marked destructive.

## Known limits

- The workspace you choose lasts for the LP server's life. Claude Code starts a separate one for
  every session, so each session asks you again. The Claude desktop app may share one between its
  chats — there, a choice made in one chat can apply in another until you quit Claude (or the
  chat asks to switch and you choose again).
- A program that writes into a page it opened earlier, in place (for example Vim with
  `backupcopy=yes`), at the very moment Claude saves the same page, can lose that write. LP and
  Obsidian save whole files and aren't affected.
- A page with a second hard link: an edit gives the page a new file, so the other link keeps the
  old text.
- Deliberate tampering by another program running on this Mac — swapping file names in the
  microseconds between the server's checks — isn't defended against beyond the checks above;
  such a program could change your files directly anyway.
- A page that can't be replaced (read-only, locked, or protected by its access list) is refused
  rather than changed.

## Connect it

**Claude Code — the easy way (LP 1.0.2 and later):** open LP and go to **Settings → Claude** (in LP 1.0.2:
**Settings → General → LP with Claude**). It shows four steps, each with its own short command and a **Copy** button, filled in for
your Mac and the workspace LP has open:

1. In Terminal, let LP's helper run — once, after downloading LP (macOS blocks programs that came in
   a download until this flag is cleared; "No such xattr" means there's nothing to do):
   `xattr -d com.apple.quarantine '/Applications/LP.app/Contents/Helpers/lp-mcp'`
2. Connect Claude Code to the workspace:
   `claude mcp add --scope user lp -- '/Applications/LP.app/Contents/Helpers/lp-mcp' --workspace '/path/to/your LP folder'`
3. Check it's connected (it says "✔ Connected" and shows this workspace's folder): `claude mcp get lp`
4. Start a new Claude Code session and ask, for example, "What's overdue in LP?" — LP asks you which
   workspace, and which folder in it, Claude may use.

If step 2 says LP is already connected, step 3 shows that connection and its scope (user, project
or local). To replace it, run `claude mcp remove lp --scope <the scope shown>` — this removes every
workspace that connection allowed — then do step 2 again. To allow several workspaces, use the
"by hand" command below with one `--workspace` per folder.
LP's in-app updates keep the helper up to date.

**Claude Code — by hand** (for every project, `--scope user`; one `--workspace` per folder Claude may
ever be offered):

```sh
xattr -d com.apple.quarantine /Applications/LP.app/Contents/Helpers/lp-mcp 2>/dev/null
claude mcp add --scope user lp -- /Applications/LP.app/Contents/Helpers/lp-mcp \
  --workspace "/path/to/your LP folder" --workspace "/path/to/another one"
claude mcp list                       # lp: ✓ Connected
```

**Claude desktop app** — first, once, in Terminal, clear the flag macOS puts on downloaded programs
(it would block the helper):

```sh
xattr -d com.apple.quarantine /Applications/LP.app/Contents/Helpers/lp-mcp
```

Then in Claude: Settings → Developer → Edit Config, and add to
`~/Library/Application Support/Claude/claude_desktop_config.json` and restart Claude:

```json
{
  "mcpServers": {
    "lp": {
      "command": "/Applications/LP.app/Contents/Helpers/lp-mcp",
      "args": ["--workspace", "/path/to/your LP folder", "--workspace", "/path/to/another one"]
    }
  }
}
```

If the workspace is in Documents or Desktop, macOS may ask once whether Claude (or your terminal)
may access that folder: allow it.

To disconnect: `claude mcp remove --scope user lp`, or delete the `lp` entry from the desktop config.

## For maintainers

- Code: `MCP/AnchoredFiles.swift` (all file access: walked from the workspace folder without following links, bounded reads, atomic swap-and-verify writes, exclusive creates), `MCP/LPVault.swift` (every operation, on LP's Foundation-only code: `Markdown/`,
  `Workspace/PageTasks.swift`, `Workspace/Safety.swift` — `PathSafety`, `SafeFileWriter`,
  `PageNaming` — and `Boards/Model/`), `MCP/MCPServer.swift` (JSON-RPC 2.0 over stdio, one message
  per line; the tool list), `MCP/main.swift`. No dependencies.
- Tests: `Scripts/test.sh mcp` — the protocol, every tool, the safety rules, Obsidian format kept.
  For a real client without installing anything:
  `claude -p --strict-mcp-config --mcp-config <json> --allowedTools "mcp__lp__*" "…"` against a
  throwaway folder.
- Lists have no IDs in a board file, so tools name them by title; cards by their stored `^id`, or by
  their title when the file has none yet (they get IDs the next time the board is changed).
- Never: delete, write outside the workspace, touch hidden folders, or rewrite a board as text.
