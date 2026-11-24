# LP for Claude (MCP)

`lp-mcp` lets Claude — **Claude Code** and the **Claude desktop app** — read and change your LP
workspace: pages, tasks and boards. It's a small program that works on the workspace folder
directly, with LP's own code, so files stay exactly as LP and Obsidian write them. LP doesn't need
to be open; when it is, it shows Claude's changes as they happen.

It runs on your Mac only. Nothing goes to LP's makers; what Claude reads goes to Claude, as with
anything you share in a conversation.

## What Claude can do

| Read | Write | Update |
|---|---|---|
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
- **Nothing is ever deleted.** A new page never replaces a file ("Plan 2" when "Plan" exists).
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
  (`lp_update_page`), changing a card (`lp_update_card`) and ticking a task off
  (`lp_set_task_done`) — so Claude can't act on something that changed after it read it. Every
  change returns the new revision for the next step.
- Results say when a scan was `incomplete` (an unreadable folder, or more than 20,000 pages); a
  daily note is then never created twice.
- In Claude, every tool except the six reading ones asks for your approval unless you allow it;
  the three that can replace text (`lp_update_page`, `lp_replace_text`, `lp_update_card`) are
  marked destructive.

## Connect it

Build it (once, and after each update of LP's code):

```sh
Scripts/build-mcp.sh                 # → .build/lp-mcp
mkdir -p ~/.local/bin && cp .build/lp-mcp ~/.local/bin/lp-mcp
```

**Claude Code** — for every project (`--scope user`):

```sh
claude mcp add --scope user lp -- ~/.local/bin/lp-mcp --workspace "/path/to/your LP folder"
claude mcp list                       # lp: ✓ Connected
```

**Claude desktop app** — Settings → Developer → Edit Config, then add to
`~/Library/Application Support/Claude/claude_desktop_config.json` and restart Claude:

```json
{
  "mcpServers": {
    "lp": {
      "command": "/Users/<you>/.local/bin/lp-mcp",
      "args": ["--workspace", "/path/to/your LP folder"]
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
