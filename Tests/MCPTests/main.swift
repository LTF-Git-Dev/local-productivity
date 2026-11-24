//
//  MCP server tests.
//
//  Run with `Scripts/test.sh mcp`. Drives LP's MCP server (`MCP/`) the way Claude does — JSON-RPC
//  lines in, lines out — against a throwaway workspace: the protocol, every tool, the safety
//  rules (nothing leaves the workspace, nothing is deleted or overwritten, odd files are left
//  alone) and that files stay exactly as LP and Obsidian write them.
//

import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if condition { passed += 1 } else { failed += 1; print("✗ line \(line): \(message())") }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("lp-mcp-tests-\(UUID().uuidString)")
let outside = fm.temporaryDirectory.appendingPathComponent("lp-mcp-outside-\(UUID().uuidString)")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }

func write(_ path: String, _ text: String) {
    let url = root.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}
func read(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
func exists(_ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }

let server = MCPServer(vault: try! LPVault(root: root))
server.today = { Day(year: 2026, month: 11, day: 24) }
var nextID = 100

/// One request; the decoded reply.
func send(_ method: String, _ params: [String: Any]? = nil, id: Any? = nil) -> [String: Any]? {
    var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
    if let params { message["params"] = params }
    if let id { message["id"] = id } else { nextID += 1; message["id"] = nextID }
    let line = String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    guard let reply = server.handle(line) else { return nil }
    check(!reply.contains("\n"), "a reply is one line")
    return try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
}

/// Calls a tool: (is it an error, its text, its JSON when it has some).
@discardableResult
func tool(_ name: String, _ arguments: [String: Any] = [:]) -> (error: Bool, text: String, json: [String: Any]) {
    let reply = send("tools/call", ["name": name, "arguments": arguments])
    let result = reply?["result"] as? [String: Any] ?? [:]
    let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "(no content: \(reply ?? [:]))"
    let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    return (result["isError"] as? Bool ?? true, text, json)
}

func allFiles() -> Set<String> {
    var found: Set<String> = []
    if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let url as URL in walker where !url.hasDirectoryPath {
            found.insert(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.resolvingSymlinksInPath().path.count + 1)))
        }
    }
    return found
}

// MARK: - Protocol

let initialize = send("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
let initResult = initialize?["result"] as? [String: Any]
check(initResult?["protocolVersion"] as? String == "2025-06-18", "a supported protocol version is accepted as asked")
check((initResult?["capabilities"] as? [String: Any])?["tools"] != nil, "the server offers tools")
check((initResult?["serverInfo"] as? [String: Any])?["name"] as? String == "lp", "the server is called lp")
check(initialize?["id"] as? Int == 101, "the reply carries the request's id")
let future = send("initialize", ["protocolVersion": "2099-01-01"])?["result"] as? [String: Any]
check(future?["protocolVersion"] as? String == MCPServer.protocolVersions[0], "an unknown version gets the newest one")
check(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "notifications get no reply")
check(server.handle("") == nil, "an empty line is ignored")
check(server.handle(#"{"jsonrpc":"2.0","id":7,"result":{}}"#) == nil, "a client's reply is ignored")
check((send("ping")?["result"] as? [String: Any]) != nil, "ping answers")
check((send("ping", id: "abc")?["id"] as? String) == "abc", "text ids are kept")
check(((send("no/such")?["error"] as? [String: Any])?["code"] as? Int) == -32601, "unknown methods: -32601")
let parseError = server.handle("{not json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
check(((parseError?["error"] as? [String: Any])?["code"] as? Int) == -32700, "bad JSON: -32700")
let badVersion = server.handle(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
check(((badVersion?["error"] as? [String: Any])?["code"] as? Int) == -32600, "not JSON-RPC 2.0: -32600")
check(((send("tools/call", ["name": "lp_nope"])?["error"] as? [String: Any])?["code"] as? Int) == -32602, "unknown tool: -32602")

let tools = (send("tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
check(tools.count == 15, "15 tools: \(tools.count)")
for item in tools {
    let schema = item["inputSchema"] as? [String: Any]
    let name = item["name"] as? String ?? "?"
    check(schema?["type"] as? String == "object", "\(name) has an object schema")
    let required = schema?["required"] as? [String] ?? []
    let properties = schema?["properties"] as? [String: Any] ?? [:]
    check(required.allSatisfy { properties[$0] != nil }, "\(name): every required argument is described")
    check((item["description"] as? String)?.isEmpty == false, "\(name) is described")
    let notes = item["annotations"] as? [String: Any]
    check(notes?["destructiveHint"] as? Bool == false, "\(name) is never destructive")
    check(name.hasPrefix("lp_"), "\(name) is prefixed")
}
let readOnly = Set(tools.filter { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }.compactMap { $0["name"] as? String })
check(readOnly == ["lp_list_pages", "lp_search", "lp_read_page", "lp_list_tasks", "lp_list_boards", "lp_read_board"],
      "exactly the six reading tools are read-only: \(readOnly.sorted())")

// Wrong argument types are explained, not crashes.
check(tool("lp_read_page", [:]).error, "a missing argument is an error")
check(tool("lp_read_page", ["path": 5]).text.contains("required"), "a number for a path is refused")
check(tool("lp_set_task_done", ["path": "x.md", "task": "a", "done": 1]).text.contains("true or false"), "1 isn't a boolean")
check(tool("lp_search", ["query": "a", "limit": 2.5]).text.contains("whole number"), "2.5 isn't a limit")
check(tool("lp_add_card", ["board": "b.md", "list": "x", "title": "t", "tags": "one"]).text.contains("list of text"), "tags must be a list")

// MARK: - The workspace

write("Welcome.md", "# Welcome\n\nThis is LP.\n")
write("Projects/Website Redesign.md", """
    # Website Redesign

    The marketing site needs a spring launch.

    - [x] Audit the current pages
    - [ ] Draft the new navigation 📅 2026-11-23
    - [ ] Review type scale with Mina 📅 2026-11-25 14:30
    - [ ] Decide on the image pipeline
    - [ ] Decide on the image pipeline

    """)
write("Areas/Café notes.markdown", "Crème brûlée recipe and the launch party.\n")
write(".lp/boards/log.md", "secret log\n")
write(".obsidian/workspace.md", "settings\n")
write("node_modules/pkg/readme.md", "library\n")
write("Projects/notes.txt", "not a page\n")
write("Projects/Hand Board.md", """
    ---

    kanban-plugin: basic

    ---

    ## To do

    - [ ] Write copy
    - [ ] Write copy
    - [ ] Shoot photos @{2026-11-20}


    ## Done

    **Complete**
    - [x] Pick a name


    %% kanban:settings
    ```
    {"kanban-plugin":"basic","lane-width":300}
    ```
    %%

    """)

// MARK: Listing and reading

let listed = tool("lp_list_pages").json
let paths = (listed["pages"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
check(paths == ["Areas/Café notes.markdown", "Projects/Hand Board.md", "Projects/Website Redesign.md", "Welcome.md"],
      "pages: Markdown only, no hidden folders or node_modules, sorted: \(paths)")
let kinds = Dictionary(uniqueKeysWithValues: (listed["pages"] as? [[String: Any]] ?? []).map { ($0["path"] as! String, $0["kind"] as! String) })
check(kinds["Projects/Hand Board.md"] == "board" && kinds["Welcome.md"] == "page", "boards are told apart")
check(((tool("lp_list_pages", ["folder": "Projects"]).json["pages"]) as? [Any])?.count == 2, "one folder")
check(tool("lp_list_pages", ["folder": ".lp"]).error, "a hidden folder can't be listed")
check(tool("lp_list_pages", ["folder": "../"]).error, "nor one above the workspace")

let welcome = tool("lp_read_page", ["path": "Welcome.md"])
check(!welcome.error && welcome.json["content"] as? String == "# Welcome\n\nThis is LP.\n", "a page reads exactly")
check((welcome.json["revision"] as? String)?.count == 16, "with a revision")
check(tool("lp_read_page", ["path": "Welcome.md"]).json["revision"] as? String == welcome.json["revision"] as? String, "the revision is stable")
check(tool("lp_read_page", ["path": "/Welcome.md"]).error, "absolute paths are refused")
check(tool("lp_read_page", ["path": "~/Welcome.md"]).error, "home paths are refused")
check(tool("lp_read_page", ["path": "Projects/../../x.md"]).error, "climbing out is refused")
check(tool("lp_read_page", ["path": ".lp/boards/log.md"]).error, "hidden folders are refused")
check(tool("lp_read_page", ["path": "Projects/notes.txt"]).error, "only Markdown files")
check(tool("lp_read_page", ["path": "Missing.md"]).text.contains("no page"), "a missing page says so")
check(tool("lp_read_page", ["path": "./Projects//Website Redesign.md"]).json["path"] as? String == "Projects/Website Redesign.md",
      "paths are tidied")

// A link inside the workspace that leads outside it.
try! Data("outside secret\n".utf8).write(to: outside.appendingPathComponent("Secret.md"))
try! fm.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: outside)
try! fm.createSymbolicLink(at: root.appendingPathComponent("Alias.md"), withDestinationURL: outside.appendingPathComponent("Secret.md"))
check(tool("lp_read_page", ["path": "Linked/Secret.md"]).error, "a folder link leading outside can't be read through")
check(tool("lp_read_page", ["path": "Alias.md"]).error, "a file link leading outside can't be read")
check(tool("lp_create_page", ["title": "Escape", "folder": "Linked"]).error, "nor written through")
check(tool("lp_append_to_page", ["path": "Alias.md", "content": "x"]).error, "nor appended to")
check(!fm.fileExists(atPath: outside.appendingPathComponent("Escape.md").path), "nothing was written outside")
check(try! String(contentsOf: outside.appendingPathComponent("Secret.md"), encoding: .utf8) == "outside secret\n", "outside is untouched")
check(!paths.contains("Alias.md"), "links aren't listed as pages")

// Files LP leaves alone.
try! Data([0x23, 0x20, 0xff, 0xfe, 0x0a]).write(to: root.appendingPathComponent("Latin.md"))
check(tool("lp_read_page", ["path": "Latin.md"]).text.contains("UTF-8"), "a non-UTF-8 file isn't read")
check(tool("lp_append_to_page", ["path": "Latin.md", "content": "x"]).error, "nor changed")
check((try? Data(contentsOf: root.appendingPathComponent("Latin.md"))) == Data([0x23, 0x20, 0xff, 0xfe, 0x0a]), "and stays byte for byte")
try! Data(repeating: 0x61, count: LPVault.maxFileSize + 1).write(to: root.appendingPathComponent("Huge.md"))
check(tool("lp_read_page", ["path": "Huge.md"]).text.contains("4 MB"), "a huge file isn't read")

// MARK: Search

let launch = tool("lp_search", ["query": "launch"]).json["results"] as? [[String: Any]] ?? []
check(launch.count == 2, "two pages mention launch: \(launch.count)")
check((launch.first?["snippet"] as? String)?.localizedCaseInsensitiveContains("launch") == true, "the snippet shows the match")
let cafe = tool("lp_search", ["query": "CAFE creme"]).json["results"] as? [[String: Any]] ?? []
check(cafe.first?["path"] as? String == "Areas/Café notes.markdown", "case and accents are ignored")
let named = tool("lp_search", ["query": "website"]).json["results"] as? [[String: Any]] ?? []
check(named.first?["path"] as? String == "Projects/Website Redesign.md", "a name match comes first")
check((tool("lp_search", ["query": "launch zebra"]).json["results"] as? [Any])?.isEmpty == true, "every word must match")
check(tool("lp_search", ["query": "  "]).error, "an empty search is refused")
check((tool("lp_search", ["query": "e", "limit": 1]).json["results"] as? [Any])?.count == 1, "the limit is kept")
check(!(tool("lp_search", ["query": "secret"]).json["results"] as? [[String: Any]] ?? []).contains { ($0["path"] as? String)?.hasPrefix(".") == true },
      "hidden files are never searched")

// MARK: Tasks

let open = tool("lp_list_tasks").json
let openTasks = open["tasks"] as? [[String: Any]] ?? []
check(open["today"] as? String == "2026-11-24", "today is reported")
check(openTasks.map { $0["text"] as? String ?? "" } == ["Shoot photos", "Draft the new navigation", "Review type scale with Mina",
                                                      "Write copy", "Write copy", "Decide on the image pipeline", "Decide on the image pipeline"],
      "open tasks, soonest due first: \(openTasks.map { $0["text"] as? String ?? "" })")
check(openTasks.first?["overdue"] as? Bool == true, "an overdue task is marked")
check(openTasks[2]["time"] as? String == "14:30" && openTasks[2]["due"] as? String == "2026-11-25", "due time and date")
check(openTasks[0]["board_list"] as? String == "To do", "a card says its list")
let done = tool("lp_list_tasks", ["status": "done"]).json["tasks"] as? [[String: Any]] ?? []
check(Set(done.compactMap { $0["text"] as? String }) == ["Audit the current pages", "Pick a name"], "done tasks, pages and boards")
check((tool("lp_list_tasks", ["status": "all"]).json["tasks"] as? [Any])?.count == 9, "all tasks")
check((tool("lp_list_tasks", ["due_by": "today"]).json["tasks"] as? [Any])?.count == 2, "due by today")
check(tool("lp_list_tasks", ["status": "soon"]).error, "an unknown status is refused")
check(tool("lp_list_tasks", ["due_by": "2026-02-30"]).error, "an impossible date is refused")
check(tool("lp_list_tasks", ["due_by": "26-1-5"]).error, "a loose date is refused")

let pageBefore = read("Projects/Website Redesign.md")!
let ticked = tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "task": "Draft the new navigation", "done": true])
check(!ticked.error && ticked.json["result"] as? String == "Ticked off.", "a task is ticked off: \(ticked.text)")
let pageAfter = read("Projects/Website Redesign.md")!
check(pageAfter == pageBefore.replacingOccurrences(of: "- [ ] Draft the new navigation", with: "- [x] Draft the new navigation"),
      "only that checkbox changed: \(pageAfter)")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "task": "Draft the new navigation", "done": true]).json["result"] as? String
      == "It was already done.", "ticking twice changes nothing")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "task": "Decide on the image pipeline", "done": true]).text.contains("ordinal"),
      "two tasks reading the same need their ordinal")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "task": "Decide on the image pipeline", "ordinal": 4, "done": true]).json["result"]
      as? String == "Ticked off.", "the ordinal picks one")
check(read("Projects/Website Redesign.md")!.hasSuffix("- [ ] Decide on the image pipeline\n- [x] Decide on the image pipeline\n"),
      "the second one, not the first: \(read("Projects/Website Redesign.md")!.suffix(80))")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "task": "Draft the new navigation", "done": false]).json["result"]
      as? String == "Reopened.", "and reopened")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "task": "Nothing like this", "done": true]).text.contains("no task"),
      "an unknown task says so")

// MARK: Writing pages

let created = tool("lp_create_page", ["title": "Meeting: Q4 / plan", "folder": "Meetings/2026", "content": "# Agenda\n- one"])
check(created.json["created"] as? String == "Meetings/2026/Meeting- Q4 - plan.md", "titles are made safe; folders made: \(created.text)")
check(read("Meetings/2026/Meeting- Q4 - plan.md") == "# Agenda\n- one\n", "with the content and a final newline")
check(tool("lp_create_page", ["title": "Welcome"]).json["created"] as? String == "Welcome 2.md", "never replaces a page")
check(read("Welcome.md") == "# Welcome\n\nThis is LP.\n", "the original is untouched")
check(tool("lp_create_page", ["title": "  "]).error, "a title is needed")
check(tool("lp_create_page", ["title": "..hidden"]).json["created"] as? String == "hidden.md", "a leading dot can't hide a page")
check(tool("lp_create_page", ["title": "x", "folder": ".obsidian"]).error, "nor be put in a hidden folder")

write("Append.md", "")
tool("lp_append_to_page", ["path": "Append.md", "content": "First"])
check(read("Append.md") == "First\n", "appending to an empty page")
tool("lp_append_to_page", ["path": "Append.md", "content": "\n\nSecond\n\n"])
check(read("Append.md") == "First\n\nSecond\n", "after one blank line, trimmed: \(read("Append.md")!.debugDescription)")
write("NoNewline.md", "Line")
tool("lp_append_to_page", ["path": "NoNewline.md", "content": "Next"])
check(read("NoNewline.md") == "Line\n\nNext\n", "a page without a final newline: \(read("NoNewline.md")!.debugDescription)")
check(tool("lp_append_to_page", ["path": "Append.md", "content": "  \n"]).error, "nothing to add is refused")
check(tool("lp_append_to_page", ["path": "Projects/Hand Board.md", "content": "x"]).text.contains("board"), "boards aren't appended to")

let replaced = tool("lp_replace_text", ["path": "Welcome.md", "find": "This is LP.", "replace_with": "This is **LP**."])
check(!replaced.error && read("Welcome.md") == "# Welcome\n\nThis is **LP**.\n", "one passage replaced")
check(tool("lp_replace_text", ["path": "Welcome.md", "find": "nowhere", "replace_with": "x"]).text.contains("isn’t on"), "missing text")
write("Twice.md", "a b a\n")
check(tool("lp_replace_text", ["path": "Twice.md", "find": "a", "replace_with": "c"]).text.contains("2 times"), "ambiguous text")
check(read("Twice.md") == "a b a\n", "an ambiguous replace changes nothing")
check(tool("lp_replace_text", ["path": "Projects/Hand Board.md", "find": "Write copy", "replace_with": "x"]).text.contains("board"), "boards refuse text edits")

let current = tool("lp_read_page", ["path": "Welcome.md"]).json["revision"] as! String
check(!tool("lp_update_page", ["path": "Welcome.md", "content": "# Hello", "revision": current]).error, "a page is rewritten")
check(read("Welcome.md") == "# Hello\n", "with the new text")
let stale = tool("lp_update_page", ["path": "Welcome.md", "content": "# Overwrite", "revision": current])
check(stale.error && stale.text.contains("changed since"), "an old revision is refused")
check(read("Welcome.md") == "# Hello\n", "and changes nothing")
check(tool("lp_update_page", ["path": "Projects/Hand Board.md", "content": "x", "revision": "x"]).text.contains("board"), "boards can't be rewritten")

// MARK: Daily notes

let note = tool("lp_daily_note")
check(note.json["path"] as? String == "2026-11-24.md" && note.json["created"] as? Bool == true, "today's note at the top: \(note.text)")
try! fm.createDirectory(at: root.appendingPathComponent("Daily Notes"), withIntermediateDirectories: true)
let tomorrow = tool("lp_daily_note", ["date": "tomorrow", "append": "- [ ] Call the printer"])
check(tomorrow.json["path"] as? String == "Daily Notes/2026-11-25.md", "in Daily Notes when it exists: \(tomorrow.text)")
check(tomorrow.json["content"] as? String == "- [ ] Call the printer\n", "with what was added")
let again = tool("lp_daily_note", ["date": "2026-11-25"])
check(again.json["created"] as? Bool == false && again.json["path"] as? String == "Daily Notes/2026-11-25.md", "found again, not duplicated")
check(tool("lp_daily_note", ["date": "2026-13-01"]).error, "an impossible date is refused")
check(tool("lp_daily_note", ["date": "yesterday", "folder": "Journal"]).json["path"] as? String == "Journal/2026-11-23.md", "a chosen folder")

// MARK: Boards

let board = tool("lp_create_board", ["title": "Launch", "template": "project", "folder": "Projects"])
check(board.json["created"] as? String == "Projects/Launch.md", "a board from a template")
check(board.json["lists"] as? [String] == ["Backlog", "Next", "In progress", "Review", "Done"], "with its lists")
check(tool("lp_create_board", ["title": "x", "template": "sprint"]).error, "an unknown template is refused")
let boardText = read("Projects/Launch.md")!
check(boardText.contains("kanban-plugin: basic") && boardText.contains("lp-board: b") && boardText.contains("%% kanban:settings"),
      "an Obsidian Kanban board with an LP board ID")

let card = tool("lp_add_card", ["board": "Projects/Launch.md", "list": "backlog", "title": "Press release", "due": "2026-11-29",
                                "time": "09:00", "tags": ["launch", "copy"], "notes": "Two paragraphs.\nOne quote."])
let cardID = card.json["added"] as? String ?? ""
check(!card.error && cardID.hasPrefix("c"), "a card is added: \(card.text)")
let read1 = tool("lp_read_board", ["path": "Projects/Launch.md"]).json
let lists1 = read1["lists"] as? [[String: Any]] ?? []
let added = (lists1.first?["cards"] as? [[String: Any]])?.first ?? [:]
check(added["id"] as? String == cardID && added["title"] as? String == "Press release", "it's read back by id and title: \(added)")
check(added["due"] as? String == "2026-11-29" && added["time"] as? String == "09:00", "with its due date and time")
check(added["tags"] as? [String] == ["launch", "copy"] && added["notes"] as? String == "Two paragraphs.\nOne quote.", "tags and notes")
check(added["done"] as? Bool == false, "open in Backlog")
check(tool("lp_add_card", ["board": "Projects/Launch.md", "list": "Someday", "title": "x"]).text.contains("Its lists"), "an unknown list names the lists")
check(tool("lp_add_card", ["board": "Welcome.md", "list": "x", "title": "x"]).text.contains("not a board"), "cards only go on boards")
check(tool("lp_add_card", ["board": "Projects/Launch.md", "list": "Done", "title": "Old win"]).error == false, "a card added to Done")
check(((tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]])?.last?["cards"] as? [[String: Any]])?.first?["done"]
      as? Bool == true, "is done")
check(tool("lp_add_card", ["board": "Projects/Launch.md", "list": "Next", "title": "x", "time": "25:00"]).error, "an impossible time is refused")

check(tool("lp_update_card", ["board": "Projects/Launch.md", "card": cardID, "title": "Press release v2", "due": "", "tags": ["pr"]]).error == false,
      "a card is edited")
let edited = ((tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]])?.first?["cards"] as? [[String: Any]])?.first ?? [:]
check(edited["title"] as? String == "Press release v2" && edited["tags"] as? [String] == ["pr"], "title and tags changed: \(edited)")
check(edited["due"] is NSNull, "an empty due date clears it")
check(edited["notes"] as? String == "Two paragraphs.\nOne quote.", "notes not mentioned stay")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "card": cardID]).text.contains("Say what"), "nothing to change is refused")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "card": cardID, "title": " "]).error, "a card needs a title")

let moved = tool("lp_update_card", ["board": "Projects/Launch.md", "card": "press release V2", "move_to_list": "done"])
check(moved.json["result"] as? String == "Updated. Moved to “Done”.", "moved by title (case ignored): \(moved.text)")
let afterMove = tool("lp_read_board", ["path": "Projects/Launch.md"]).json
check((afterMove["progress"] as? [String: Any])?["done"] as? Int == 2, "moving into Done counts it done")
check((tool("lp_list_boards").json["boards"] as? [[String: Any]])?.first { $0["path"] as? String == "Projects/Launch.md" }?["percent_done"] as? Int == 100,
      "progress is listed per board")
let reopened = tool("lp_update_card", ["board": "Projects/Launch.md", "card": cardID, "done": false])
check(reopened.json["result"] as? String == "Updated. Moved to “Backlog”.", "reopening a done card moves it to the first open list: \(reopened.text)")
tool("lp_add_card", ["board": "Projects/Launch.md", "list": "Review", "title": "Proofread"])
tool("lp_update_card", ["board": "Projects/Launch.md", "card": cardID, "move_to_list": "Review", "before_card": "Proofread"])
let review = ((tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]])?[3]["cards"] as? [[String: Any]] ?? [])
check(review.map { $0["title"] as? String ?? "" } == ["Press release v2", "Proofread"], "placed before a card: \(review)")
check(tool("lp_set_task_done", ["path": "Projects/Launch.md", "task": cardID, "done": true]).json["result"] as? String == "Updated.",
      "a card is ticked off like a task")
check(((tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]])?[3]["cards"] as? [[String: Any]])?.first?["done"]
      as? Bool == true, "and stays in its list, done")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "card": cardID, "move_to_list": "Nowhere"]).text.contains("no list"), "an unknown list")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "card": "ghost", "done": true]).text.contains("no card"), "an unknown card")

// A board written by hand (no card IDs): cards are found by title, and get IDs when it's changed.
let hand = tool("lp_read_board", ["path": "Projects/Hand Board.md"]).json
let handCards = (hand["lists"] as? [[String: Any]])?.first?["cards"] as? [[String: Any]] ?? []
check(handCards.allSatisfy { $0["id"] is NSNull }, "cards without stored ids show none")
check(tool("lp_update_card", ["board": "Projects/Hand Board.md", "card": "Write copy", "done": true]).text.contains("2 cards"),
      "two cards with one title need an id")
check(read("Projects/Hand Board.md")!.contains("- [ ] Write copy\n- [ ] Write copy\n"), "reading and refusing never wrote the board")
check(!tool("lp_update_card", ["board": "Projects/Hand Board.md", "card": "Shoot photos", "move_to_list": "Done"]).error, "moved by title")
let handAfter = read("Projects/Hand Board.md")!
check(handAfter.contains("{\"kanban-plugin\":\"basic\",\"lane-width\":300}"), "the board's own settings are kept")
check(handAfter.contains("**Complete**") && handAfter.contains("\n\n\n## Done"), "the Kanban layout is kept: \(handAfter)")
let ids = (tool("lp_read_board", ["path": "Projects/Hand Board.md"]).json["lists"] as? [[String: Any]] ?? [])
    .flatMap { $0["cards"] as? [[String: Any]] ?? [] }.map { $0["id"] }
check(ids.allSatisfy { $0 is String }, "every card has a stored id now")
let firstCopy = (((tool("lp_read_board", ["path": "Projects/Hand Board.md"]).json["lists"] as? [[String: Any]])?.first?["cards"]) as? [[String: Any]])?.first?["id"] as? String ?? ""
check(!tool("lp_update_card", ["board": "Projects/Hand Board.md", "card": firstCopy, "done": true]).error, "then one copy is picked by id")
check(BoardParser.serialize(BoardParser.parse(read("Projects/Hand Board.md")!)) == read("Projects/Hand Board.md")!,
      "the board is exactly as LP writes it")

// MARK: Nothing is ever deleted

let before = allFiles()
for _ in 0..<2 {
    tool("lp_create_page", ["title": "Welcome"])
    tool("lp_update_card", ["board": "Projects/Launch.md", "card": cardID, "move_to_list": "Backlog"])
    tool("lp_daily_note", ["append": "more"])
}
check(before.isSubset(of: allFiles()), "every file is still there: \(before.subtracting(allFiles()))")
check(read(".lp/boards/log.md") == "secret log\n" && read(".obsidian/workspace.md") == "settings\n", "hidden files are untouched")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
