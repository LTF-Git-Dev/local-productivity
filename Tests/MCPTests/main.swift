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

let second = fm.temporaryDirectory.appendingPathComponent("lp-mcp-second-\(UUID().uuidString)")
try! fm.createDirectory(at: second.appendingPathComponent("Journal"), withIntermediateDirectories: true)
defer { try? fm.removeItem(at: second) }
let server = try! MCPServer(workspaces: [root, second])
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

/// A board's current revision, as Claude gets it from lp_read_board.
func rev(_ board: String) -> String { tool("lp_read_board", ["path": board]).json["revision"] as? String ?? "?" }
/// A page's current revision, as Claude gets it from lp_read_page.
func pageRev(_ page: String) -> String { tool("lp_read_page", ["path": page]).json["revision"] as? String ?? "?" }

/// The person's answer to LP's "which workspace?" form, as the Claude app sends it back.
var nextAnswer: [String: Any]?
var lastAsked: [String: Any]?
server.sendRequest = { request in
    lastAsked = request
    defer { nextAnswer = nil }
    return nextAnswer
}
@discardableResult
func choose(_ workspace: String, folder: String? = nil, action: String = "accept") -> (error: Bool, text: String, json: [String: Any]) {
    var content: [String: Any] = ["workspace": workspace]
    if let folder { content["folder"] = folder }
    nextAnswer = ["jsonrpc": "2.0", "id": "lp-ask-1", "result": ["action": action, "content": content]]
    return tool("lp_use_workspace")
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

let initialize = send("initialize", ["protocolVersion": "2025-06-18", "capabilities": ["elicitation": ["form": [:]]],
                                     "clientInfo": ["name": "test", "version": "1"]])
let initResult = initialize?["result"] as? [String: Any]
check(initResult?["protocolVersion"] as? String == "2025-06-18", "a supported protocol version is accepted as asked")
check((initResult?["capabilities"] as? [String: Any])?["tools"] != nil, "the server offers tools")
check((initResult?["serverInfo"] as? [String: Any])?["name"] as? String == "lp", "the server is called lp")
check(initialize?["id"] as? Int == 101, "the reply carries the request's id")
let future = send("initialize", ["protocolVersion": "2099-01-01", "capabilities": ["elicitation": [:]]])?["result"] as? [String: Any]
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
check(tools.count == 17, "17 tools: \(tools.count)")
for item in tools {
    let schema = item["inputSchema"] as? [String: Any]
    let name = item["name"] as? String ?? "?"
    check(schema?["type"] as? String == "object", "\(name) has an object schema")
    let required = schema?["required"] as? [String] ?? []
    let properties = schema?["properties"] as? [String: Any] ?? [:]
    check(required.allSatisfy { properties[$0] != nil }, "\(name): every required argument is described")
    check((item["description"] as? String)?.isEmpty == false, "\(name) is described")
    let notes = item["annotations"] as? [String: Any]
    let replacesText = ["lp_replace_text", "lp_update_page", "lp_update_card"].contains(name)
    check(notes?["destructiveHint"] as? Bool == replacesText, "\(name): destructive only if it can replace text that's there")
    check(name.hasPrefix("lp_"), "\(name) is prefixed")
}
let readOnly = Set(tools.filter { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }.compactMap { $0["name"] as? String })
check(readOnly == ["lp_list_workspaces", "lp_list_pages", "lp_search", "lp_read_page", "lp_list_tasks", "lp_list_boards", "lp_read_board"],
      "exactly the seven reading tools are read-only: \(readOnly.sorted())")

// MARK: Choosing a workspace first

check(tool("lp_list_pages").text.contains("asks the person directly"), "nothing works before a workspace is chosen")
check(tool("lp_daily_note").text.contains("asks the person directly"), "nothing is written either")
check(!exists("2026-11-24.md"), "and no note was made")
let beforeChoice = tool("lp_list_workspaces").json
check(beforeChoice["allowed"] as? Int == 2 && beforeChoice["chosen"] is NSNull, "before a choice: only how many workspaces are allowed")
check(!tool("lp_list_workspaces").text.contains(root.lastPathComponent), "not even their names")
let declined = choose(root.lastPathComponent, action: "decline")
check(declined.error && declined.text.contains("didn’t choose"), "declining the form chooses nothing")
let offered = ((((lastAsked?["params"] as? [String: Any])?["requestedSchema"] as? [String: Any])?["properties"] as? [String: Any])?["workspace"] as? [String: Any])?["enum"] as? [String]
check(lastAsked?["method"] as? String == "elicitation/create", "the person is asked with a form")
check(offered == [root.lastPathComponent, second.lastPathComponent], "offering exactly the allowed workspaces: \(offered ?? [])")
check(tool("lp_list_pages").text.contains("lp_use_workspace"), "still nothing works")
nextAnswer = nil
check(tool("lp_use_workspace").text.contains("wasn’t asked"), "no answer chooses nothing")
check(choose(root.lastPathComponent.uppercased()).text.contains("isn’t an allowed"), "the name must match exactly")
check(choose("Elsewhere").text.contains("isn’t an allowed workspace"), "only allowed workspaces can be chosen")
check(choose(second.lastPathComponent, folder: "Missing").error, "a missing folder can't be chosen")
check(choose(second.lastPathComponent, folder: "../").error, "nor one above the workspace")
let chosen = choose(root.lastPathComponent)
check(!chosen.error, "the person's choice is used: \(chosen.text)")
check(((tool("lp_list_workspaces").json["chosen"] as? [String: Any])?["workspace"] as? String) == root.lastPathComponent, "and reported as chosen")

// Switching starts from nothing: declining a new choice leaves no workspace in use.
check(choose(second.lastPathComponent, action: "decline").error, "a later choice is declined")
check(tool("lp_list_pages").text.contains("asks the person directly"), "and the earlier workspace is no longer in use")
nextAnswer = ["jsonrpc": "2.0", "id": "lp-ask-1", "result": ["action": "accept", "content": ["workspace": root.lastPathComponent, "folder": 5]]]
check(tool("lp_use_workspace").text.contains("wasn’t text"), "a folder answer that isn't text grants nothing")
check(tool("lp_list_pages").text.contains("asks the person directly"), "still nothing in use")
nextAnswer = ["jsonrpc": "2.0", "id": "lp-ask-1", "result": ["action": "accept", "content": ["workspace": root.lastPathComponent, "folder": NSNull()]]]
check(tool("lp_use_workspace").text.contains("wasn’t text"), "nor does a null folder")
check(MCPServer.sameID(7, 7) && MCPServer.sameID("7", "7"), "ids match themselves")
check(!MCPServer.sameID(7, "7") && !MCPServer.sameID("7", 7), "but 7 and \"7\" are different ids")
check(!MCPServer.sameID(true, 1), "and true isn't an id")
nextAnswer = ["cancelled": true]
let cancelledCall = send("tools/call", ["name": "lp_use_workspace", "arguments": [:]])
check(cancelledCall == nil, "a call cancelled while asking gets no answer")
check(!choose(root.lastPathComponent).error, "and the person can choose again")

// Apps that can't show a form: refused — unless LP was started to accept the choice from the chat.
let noForms = try! MCPServer(workspaces: [root])
_ = noForms.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
let noFormsReply = noForms.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"lp_use_workspace","arguments":{"workspace":"x"}}}"#) ?? ""
check(noFormsReply.contains("can’t show the person a form") && noFormsReply.contains("\"isError\":true"), "an app without forms can't choose")
let inChat = try! MCPServer(workspaces: [root], allowChoiceInChat: true)
_ = inChat.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
let inChatReply = inChat.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"lp_use_workspace","arguments":{"workspace":"\#(root.lastPathComponent)"}}}"#) ?? ""
check(inChatReply.contains("\"isError\":false"), "with --allow-choice-in-chat, Claude passes the choice on: \(inChatReply.prefix(160))")

// Wrong argument types are explained, not crashes.
check(tool("lp_read_page", [:]).error, "a missing argument is an error")
check(tool("lp_read_page", ["path": 5]).text.contains("required"), "a number for a path is refused")
check(tool("lp_set_task_done", ["path": "x.md", "revision": pageRev("x.md"), "task": "a", "done": 1]).text.contains("true or false"), "1 isn't a boolean")
check(tool("lp_search", ["query": "a", "limit": 2.5]).text.contains("whole number"), "2.5 isn't a limit")
check(tool("lp_add_card", ["board": "b.md", "revision": rev("b.md"), "list": "x", "title": "t", "tags": "one"]).text.contains("list of text"), "tags must be a list")

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
let ticked = tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "revision": pageRev("Projects/Website Redesign.md"), "task": "Draft the new navigation", "done": true])
check(!ticked.error && ticked.json["result"] as? String == "Ticked off.", "a task is ticked off: \(ticked.text)")
let pageAfter = read("Projects/Website Redesign.md")!
check(pageAfter == pageBefore.replacingOccurrences(of: "- [ ] Draft the new navigation", with: "- [x] Draft the new navigation"),
      "only that checkbox changed: \(pageAfter)")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "revision": pageRev("Projects/Website Redesign.md"), "task": "Draft the new navigation", "done": true]).json["result"] as? String
      == "It was already done.", "ticking twice changes nothing")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "revision": pageRev("Projects/Website Redesign.md"), "task": "Decide on the image pipeline", "done": true]).text.contains("ordinal"),
      "two tasks reading the same need their ordinal")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "task": "Decide on the image pipeline", "ordinal": 4,
                        "revision": pageRev("Projects/Website Redesign.md"), "done": true]).json["result"]
      as? String == "Ticked off.", "the ordinal picks one")
check(read("Projects/Website Redesign.md")!.hasSuffix("- [ ] Decide on the image pipeline\n- [x] Decide on the image pipeline\n"),
      "the second one, not the first: \(read("Projects/Website Redesign.md")!.suffix(80))")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "revision": pageRev("Projects/Website Redesign.md"), "task": "Draft the new navigation", "done": false]).json["result"]
      as? String == "Reopened.", "and reopened")
check(tool("lp_set_task_done", ["path": "Projects/Website Redesign.md", "revision": pageRev("Projects/Website Redesign.md"), "task": "Nothing like this", "done": true]).text.contains("no task"),
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

let card = tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "backlog", "title": "Press release", "due": "2026-11-29",
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
check(tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Someday", "title": "x"]).text.contains("Its lists"), "an unknown list names the lists")
check(tool("lp_add_card", ["board": "Welcome.md", "revision": rev("Welcome.md"), "list": "x", "title": "x"]).text.contains("not a board"), "cards only go on boards")
check(tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Done", "title": "Old win"]).error == false, "a card added to Done")
check(((tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]])?.last?["cards"] as? [[String: Any]])?.first?["done"]
      as? Bool == true, "is done")
check(tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Next", "title": "x", "time": "25:00"]).error, "an impossible time is refused")

check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": cardID, "title": "Press release v2", "due": "", "tags": ["pr"]]).error == false,
      "a card is edited")
let edited = ((tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]])?.first?["cards"] as? [[String: Any]])?.first ?? [:]
check(edited["title"] as? String == "Press release v2" && edited["tags"] as? [String] == ["pr"], "title and tags changed: \(edited)")
check(edited["due"] is NSNull, "an empty due date clears it")
check(edited["notes"] as? String == "Two paragraphs.\nOne quote.", "notes not mentioned stay")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": cardID]).text.contains("Say what"), "nothing to change is refused")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": cardID, "title": " "]).error, "a card needs a title")

let moved = tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": "press release V2", "move_to_list": "done"])
check(moved.json["result"] as? String == "Updated. Moved to “Done”.", "moved by title (case ignored): \(moved.text)")
let afterMove = tool("lp_read_board", ["path": "Projects/Launch.md"]).json
check((afterMove["progress"] as? [String: Any])?["done"] as? Int == 2, "moving into Done counts it done")
check((tool("lp_list_boards").json["boards"] as? [[String: Any]])?.first { $0["path"] as? String == "Projects/Launch.md" }?["percent_done"] as? Int == 100,
      "progress is listed per board")
let reopened = tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": cardID, "done": false])
check(reopened.json["result"] as? String == "Updated. Moved to “Backlog”.", "reopening a done card moves it to the first open list: \(reopened.text)")
tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Review", "title": "Proofread"])
tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": cardID, "move_to_list": "Review", "before_card": "Proofread"])
let review = ((tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]])?[3]["cards"] as? [[String: Any]] ?? [])
check(review.map { $0["title"] as? String ?? "" } == ["Press release v2", "Proofread"], "placed before a card: \(review)")
check(tool("lp_set_task_done", ["path": "Projects/Launch.md", "revision": pageRev("Projects/Launch.md"), "task": cardID, "done": true]).json["result"] as? String == "Updated.",
      "a card is ticked off like a task")
check(((tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]])?[3]["cards"] as? [[String: Any]])?.first?["done"]
      as? Bool == true, "and stays in its list, done")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": cardID, "move_to_list": "Nowhere"]).text.contains("no list"), "an unknown list")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": "ghost", "done": true]).text.contains("no card"), "an unknown card")

// A board written by hand (no card IDs): cards are found by title, and get IDs when it's changed.
let hand = tool("lp_read_board", ["path": "Projects/Hand Board.md"]).json
let handCards = (hand["lists"] as? [[String: Any]])?.first?["cards"] as? [[String: Any]] ?? []
check(handCards.allSatisfy { $0["id"] is NSNull }, "cards without stored ids show none")
check(tool("lp_update_card", ["board": "Projects/Hand Board.md", "revision": rev("Projects/Hand Board.md"), "card": "Write copy", "done": true]).text.contains("2 cards"),
      "two cards with one title need an id")
check(read("Projects/Hand Board.md")!.contains("- [ ] Write copy\n- [ ] Write copy\n"), "reading and refusing never wrote the board")
check(!tool("lp_update_card", ["board": "Projects/Hand Board.md", "revision": rev("Projects/Hand Board.md"), "card": "Shoot photos", "move_to_list": "Done"]).error, "moved by title")
let handAfter = read("Projects/Hand Board.md")!
check(handAfter.contains("{\"kanban-plugin\":\"basic\",\"lane-width\":300}"), "the board's own settings are kept")
check(handAfter.contains("**Complete**") && handAfter.contains("\n\n\n## Done"), "the Kanban layout is kept: \(handAfter)")
let ids = (tool("lp_read_board", ["path": "Projects/Hand Board.md"]).json["lists"] as? [[String: Any]] ?? [])
    .flatMap { $0["cards"] as? [[String: Any]] ?? [] }.map { $0["id"] }
check(ids.allSatisfy { $0 is String }, "every card has a stored id now")
let firstCopy = (((tool("lp_read_board", ["path": "Projects/Hand Board.md"]).json["lists"] as? [[String: Any]])?.first?["cards"]) as? [[String: Any]])?.first?["id"] as? String ?? ""
check(!tool("lp_update_card", ["board": "Projects/Hand Board.md", "revision": rev("Projects/Hand Board.md"), "card": firstCopy, "done": true]).error, "then one copy is picked by id")
check(BoardParser.serialize(BoardParser.parse(read("Projects/Hand Board.md")!)) == read("Projects/Hand Board.md")!,
      "the board is exactly as LP writes it")

// MARK: Review fixes (Codex round 1)

// Protocol: malformed arguments and ids.
let notObject = send("tools/call", ["name": "lp_daily_note", "arguments": "invalid"])
check(((notObject?["error"] as? [String: Any])?["code"] as? Int) == -32602, "arguments that aren't an object are refused")
check(!exists("2026-11-24 2.md"), "and create nothing")
let misspelt = tool("lp_list_tasks", ["stauts": "done"])
check(misspelt.error && misspelt.text.contains("no argument “stauts”"), "a misspelt argument is refused, not ignored: \(misspelt.text)")
let boolID = server.handle(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
check(((boolID?["error"] as? [String: Any])?["code"] as? Int) == -32600, "true isn't a request id")
check(tool("lp_list_pages").json["incomplete"] as? Bool == false, "a full scan says it's complete")

// Paths are used exactly: " Note.md" isn't "Note.md".
write("Note.md", "plain\n")
write(" Note.md", "spaced\n")
check(tool("lp_read_page", ["path": " Note.md"]).json["content"] as? String == "spaced\n", "a leading space names its own page")
tool("lp_append_to_page", ["path": " Note.md", "content": "more"])
check(read("Note.md") == "plain\n", "and the other page is untouched")

// A link that stays inside but names a hidden folder.
try! fm.createSymbolicLink(at: root.appendingPathComponent("Visible"), withDestinationURL: root.appendingPathComponent(".obsidian"))
check(tool("lp_read_page", ["path": "Visible/workspace.md"]).text.contains("link"), "a link to a hidden folder can't be read through")
check(tool("lp_append_to_page", ["path": "Visible/workspace.md", "content": "x"]).error, "nor written through")
check(tool("lp_create_page", ["title": "x", "folder": "Visible"]).error, "nor used as a folder")
check(read(".obsidian/workspace.md") == "settings\n", "the hidden file is untouched")

// A named pipe called like a page neither blocks nor is listed.
check(mkfifo(root.appendingPathComponent("Pipe.md").path, 0o644) == 0, "a pipe was made")
check(!((tool("lp_list_pages").json["pages"] as? [[String: Any]]) ?? []).contains { $0["path"] as? String == "Pipe.md" }, "a pipe isn't listed")
check(tool("lp_read_page", ["path": "Pipe.md"]).text.contains("regular file"), "nor read (and nothing hangs)")
check(tool("lp_list_tasks").error == false && tool("lp_search", ["query": "plain"]).error == false, "scans skip it")

// Nothing is written that can't be read back.
let big = String(repeating: "a", count: LPVault.maxFileSize)
check(tool("lp_append_to_page", ["path": "Note.md", "content": big]).text.contains("4 MB"), "a page can't grow past 4 MB")
check(tool("lp_create_page", ["title": "Big", "content": big + "b"]).text.contains("4 MB"), "nor start past it")
check(read("Note.md") == "plain\n" && !exists("Big.md"), "and nothing was written")

// Card text can't change a board's structure.
check(tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Next", "title": "x", "tags": ["ok\n## Hacked\n- [ ] Evil"]]).text.contains("isn’t a tag"),
      "a tag with a line break is refused")
check(tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Next", "title": "x", "tags": ["two words"]]).error, "and one with a space")
let tidy = tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Next", "title": "Line one\n## Fake list\r- [ ] Fake card", "tags": ["#ok", "a/b-c_d"]])
let tidyID = tidy.json["added"] as? String ?? "?"
check(!tidy.error, "a title with line breaks is added on one line: \(tidy.text)")
let lanes = (tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]] ?? [])
check(lanes.map { $0["title"] as? String ?? "" } == ["Backlog", "Next", "In progress", "Review", "Done"], "no list was injected: \(lanes.map { $0["title"] ?? "" })")
let tidyCard = lanes.count > 1 ? (lanes[1]["cards"] as? [[String: Any]] ?? []).first { $0["id"] as? String == tidyID } : nil
check(tidyCard?["title"] as? String == "Line one ## Fake list - [ ] Fake card", "the title stays one line: \(tidyCard?["title"] ?? "")")
check(tidyCard?["tags"] as? [String] == ["ok", "a/b-c_d"], "tags lose their #")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": tidyID, "notes": "one\r\ntwo"]).error == false, "notes with Windows line breaks")
check(((tool("lp_read_board", ["path": "Projects/Launch.md"]).json["lists"] as? [[String: Any]])?[1]["cards"] as? [[String: Any]] ?? [])
      .first { $0["id"] as? String == tidyID }?["notes"] as? String == "one\ntwo", "are kept as two lines")

// Impossible card changes are explained, not reported as done.
check(tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Next", "title": "x", "time": "10:00"]).text.contains("due date"),
      "a time without a date is refused")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": tidyID, "time": "10:00"]).text.contains("due date"), "on an undated card too")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": tidyID, "move_to_list": "Done", "done": false]).text.contains("can’t be open"),
      "open in a list that counts as done is refused")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": tidyID, "move_to_list": "Review", "before_card": "Old win"]).text.contains("isn’t in"),
      "before a card in another list is refused")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": tidyID, "title": "y", "before_card": "Old win"]).text.contains("only works with"),
      "before_card alone is refused")
write("AllDone.md", "---\n\nkanban-plugin: basic\n\n---\n\n## Finished\n\n**Complete**\n- [x] Shipped ^cship01\n\n\n")
check(tool("lp_update_card", ["board": "AllDone.md", "revision": rev("AllDone.md"), "card": "cship01", "done": false]).text.contains("Every list"),
      "a card can't be reopened when every list counts as done")

// Look-alike tasks with different due dates.
write("Reports.md", "- [ ] Send report 📅 2026-11-30\n- [ ] Send report 📅 2026-11-25\n")
check(tool("lp_set_task_done", ["path": "Reports.md", "revision": pageRev("Reports.md"), "task": "Send report", "due": "2026-11-25", "done": true]).json["result"] as? String == "Ticked off.",
      "the due date tells look-alikes apart")
check(read("Reports.md") == "- [ ] Send report 📅 2026-11-30\n- [x] Send report 📅 2026-11-25\n", "the right one: \(read("Reports.md") ?? "")")
check(tool("lp_set_task_done", ["path": "Reports.md", "revision": pageRev("Reports.md"), "task": "Send report", "ordinal": 1, "due": "2026-11-30", "done": true]).json["result"]
      as? String == "Ticked off.", "a stale ordinal can't override the due date")
check(read("Reports.md") == "- [x] Send report 📅 2026-11-30\n- [x] Send report 📅 2026-11-25\n", "still the one with that date")

// MARK: Review fixes (Codex round 2)

// A save that lands between reading and writing is never lost: the swap puts it back.
write("Race.md", "theirs, saved meanwhile\n")
let raced = try! server.vault!.files.replace("Race.md", with: Data("ours\n".utf8), expected: Data("what we read\n".utf8))
check(raced == .changedMeanwhile, "a replace over a file that changed reports it")
check(read("Race.md") == "theirs, saved meanwhile\n", "and their save stands: \(read("Race.md") ?? "")")
let clean = try! server.vault!.files.replace("Race.md", with: Data("ours\n".utf8), expected: Data("theirs, saved meanwhile\n".utf8))
check(clean == .done && read("Race.md") == "ours\n", "over the version it read, it's replaced")
check(!allFiles().contains { ($0 as NSString).lastPathComponent.hasPrefix(".lp-mcp-") }, "no temporary files are left behind")

// What a file carries besides its text survives an edit: Finder tags and its creation date.
write("Tagged.md", "x\n")
let taggedURL = root.appendingPathComponent("Tagged.md")
try! (taggedURL as NSURL).setResourceValue(["Important"], forKey: .tagNamesKey)
let born = Date(timeIntervalSince1970: 1_700_000_000)
try! fm.setAttributes([.creationDate: born], ofItemAtPath: taggedURL.path)
tool("lp_append_to_page", ["path": "Tagged.md", "content": "y"])
let tagNames = (try? URL(fileURLWithPath: taggedURL.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames
check(tagNames == ["Important"], "Finder tags survive an edit: \(tagNames ?? [])")
let creation = (try? fm.attributesOfItem(atPath: taggedURL.path))?[.creationDate] as? Date
check(creation.map { abs($0.timeIntervalSince(born)) < 1 } == true, "and so does the creation date: \(String(describing: creation))")
check(read("Tagged.md") == "x\n\ny\n", "with the new text")

// Card edits name the board version they're based on; each change hands back the next one.
let board1 = rev("Projects/Launch.md")
let addedCard = tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Next", "title": "Chained"])
let chained = tool("lp_update_card", ["board": "Projects/Launch.md", "revision": addedCard.json["revision"] as? String ?? "",
                                      "card": addedCard.json["added"] as? String ?? "", "move_to_list": "Review"])
check(!chained.error, "the revision an add returns is enough for the next change: \(chained.text)")
let staleCard = tool("lp_update_card", ["board": "Projects/Launch.md", "revision": board1, "card": "Chained", "notes": "overwrite"])
check(staleCard.error && staleCard.text.contains("changed since"), "a revision from before is refused")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "card": "Chained", "title": "x"]).text.contains("“revision” is required"),
      "lp_update_card needs a revision")
check(tool("lp_set_task_done", ["path": "Projects/Launch.md", "task": "Chained", "revision": board1, "done": true]).text.contains("changed since"),
      "so does ticking a card off, when it gives one")
check(tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": "Chained",
                              "move_to_list": "Review", "before_card": "Chained"]).text.contains("before itself"), "a card can't go before itself")

// Look-alike tasks: the ordinal counts only with the page's revision.
write("Same.md", "- [ ] Call 📅 2026-11-26 09:00\n- [ ] Call 📅 2026-11-26 15:00\n")
check(tool("lp_set_task_done", ["path": "Same.md", "task": "Call", "ordinal": 1, "done": true]).text.contains("“revision” is required"),
      "ticking off needs the revision it was listed with")
check(tool("lp_set_task_done", ["path": "Same.md", "revision": pageRev("Same.md"), "task": "Call", "time": "15:00", "done": true]).json["result"] as? String == "Ticked off.",
      "the time tells them apart")
check(read("Same.md") == "- [ ] Call 📅 2026-11-26 09:00\n- [x] Call 📅 2026-11-26 15:00\n", "the 15:00 one: \(read("Same.md") ?? "")")
let sameTasks = (tool("lp_list_tasks", ["status": "all", "folder": ""]).json["tasks"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "Same.md" }
check(sameTasks.allSatisfy { ($0["revision"] as? String)?.count == 16 }, "listed tasks carry their page's revision")
write("Same.md", "- [ ] Call\n- [ ] Call\n")
let sameRevision = pageRev("Same.md")
check(tool("lp_set_task_done", ["path": "Same.md", "task": "Call", "ordinal": 1, "revision": sameRevision, "done": true]).json["result"]
      as? String == "Ticked off.", "with the revision, the ordinal picks one")
check(tool("lp_set_task_done", ["path": "Same.md", "task": "Call", "ordinal": 0, "revision": sameRevision, "done": true]).text.contains("changed since"),
      "and an old revision is refused")

// Folders are used exactly as given.
check(tool("lp_create_page", ["title": "In spaced", "folder": " Spaced"]).json["created"] as? String == " Spaced/In spaced.md", "a folder with a leading space")
check(!exists("Spaced"), "isn't confused with one without")
check((tool("lp_list_pages", ["folder": " Spaced"]).json["pages"] as? [Any])?.count == 1, "and is listed as itself")

// Null arguments and number-only tags.
let nullArguments = send("tools/call", ["name": "lp_daily_note", "arguments": NSNull()])
check(((nullArguments?["error"] as? [String: Any])?["code"] as? Int) == -32602, "null arguments are refused")
check(tool("lp_add_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "list": "Next", "title": "x", "tags": ["123"]]).text.contains("not only digits"),
      "a number-only tag is refused (LP wouldn't read it as a tag)")

// A folder that can't be read makes a scan incomplete — and then no daily note is made twice.
write("Locked/2026-12-01.md", "the note\n")
chmod(root.appendingPathComponent("Locked").path, 0o000)
check(tool("lp_list_pages").json["incomplete"] as? Bool == true, "an unreadable folder makes the scan incomplete")
check(tool("lp_daily_note", ["date": "2026-12-01"]).text.contains("couldn’t be scanned"), "and no second note is created")
chmod(root.appendingPathComponent("Locked").path, 0o755)
check(tool("lp_daily_note", ["date": "2026-12-01"]).json["path"] as? String == "Locked/2026-12-01.md", "once readable, the note is found")

// A folder replaced by a link is refused when it's walked, for reading and writing alike.
try! fm.createDirectory(at: root.appendingPathComponent("Swap"), withIntermediateDirectories: true)
write("Swap/Doc.md", "inside\n")
try! fm.removeItem(at: root.appendingPathComponent("Swap"))
try! fm.createSymbolicLink(at: root.appendingPathComponent("Swap"), withDestinationURL: outside)
try! Data("outside doc\n".utf8).write(to: outside.appendingPathComponent("Doc.md"))
check(tool("lp_read_page", ["path": "Swap/Doc.md"]).text.contains("link"), "a swapped-in link is refused for reading")
check(tool("lp_append_to_page", ["path": "Swap/Doc.md", "content": "x"]).error, "and for writing")
check(tool("lp_create_page", ["title": "New", "folder": "Swap/Deeper"]).error, "and for making folders")
check(try! String(contentsOf: outside.appendingPathComponent("Doc.md"), encoding: .utf8) == "outside doc\n", "outside is untouched")
check(!fm.fileExists(atPath: outside.appendingPathComponent("Deeper").path), "no folder was made outside")

// MARK: Review fixes (Codex round 3)

let firstListing = tool("lp_list_pages").json["pages"] as? [[String: Any]] ?? []
let secondListing = tool("lp_list_pages").json["pages"] as? [[String: Any]] ?? []
check(!firstListing.isEmpty && firstListing.count == secondListing.count, "listing twice finds the same pages (\(firstListing.count), \(secondListing.count))")
write("Tool.app/Contents/Readme.md", "inside an app\n")
check(!(tool("lp_list_pages").json["pages"] as? [[String: Any]] ?? []).contains { ($0["path"] as? String)?.hasPrefix("Tool.app") == true },
      "nothing inside a package (an .app) is listed")
check(!allFiles().contains { ($0 as NSString).lastPathComponent.hasPrefix(".lp-mcp-") }, "creates and edits leave no hidden temporary files")

// MARK: Review fixes (Codex round 4)

write("ReadOnly.md", "keep me\n")
chmod(root.appendingPathComponent("ReadOnly.md").path, 0o444)
check(tool("lp_append_to_page", ["path": "ReadOnly.md", "content": "x"]).text.contains("read-only"), "a read-only page isn't changed")
check(read("ReadOnly.md") == "keep me\n", "and keeps its text")
check(((try? fm.attributesOfItem(atPath: root.appendingPathComponent("ReadOnly.md").path))?[.posixPermissions] as? Int) == 0o444, "and stays read-only")
chmod(root.appendingPathComponent("ReadOnly.md").path, 0o644)
write("Locked.md", "locked\n")
check(chflags(root.appendingPathComponent("Locked.md").path, UInt32(UF_IMMUTABLE)) == 0, "Finder's Locked was set")
check(tool("lp_replace_text", ["path": "Locked.md", "find": "locked", "replace_with": "open"]).text.contains("locked"), "a locked page isn't changed")
check(read("Locked.md") == "locked\n", "and keeps its text")
chflags(root.appendingPathComponent("Locked.md").path, 0)
check(tool("lp_replace_text", ["path": "Locked.md", "find": "locked", "replace_with": "open"]).error == false, "once unlocked, it can be")

// MARK: Review fixes (Codex round 5)

// Finder-hidden folders (no leading dot) are hidden too.
write("Secret Stuff/Plan.md", "hidden plan\n")
check(chflags(root.appendingPathComponent("Secret Stuff").path, UInt32(UF_HIDDEN)) == 0, "a folder was hidden in Finder")
check(!(tool("lp_list_pages").json["pages"] as? [[String: Any]] ?? []).contains { ($0["path"] as? String)?.hasPrefix("Secret Stuff") == true },
      "it isn't listed")
check(tool("lp_read_page", ["path": "Secret Stuff/Plan.md"]).text.contains("hidden"), "nor read by path")
check(tool("lp_create_page", ["title": "x", "folder": "Secret Stuff"]).text.contains("hidden"), "nor written into")

// What an edit keeps: flags, group and access lists.
write("Kept.md", "kept\n")
let keptPath = root.appendingPathComponent("Kept.md").path
check(chflags(keptPath, UInt32(UF_NODUMP)) == 0, "a flag was set")
let everyone: gid_t = 12   // "everyone": a group every Mac user belongs to
check(chown(keptPath, uid_t.max, everyone) == 0, "the group was changed")
let aclSet = Process()
aclSet.executableURL = URL(fileURLWithPath: "/bin/chmod")
aclSet.arguments = ["+a", "everyone allow readattr", keptPath]
try! aclSet.run(); aclSet.waitUntilExit()
func aclText(_ path: String) -> String? {
    guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED), let text = acl_to_text(acl, nil) else { return nil }
    defer { acl_free(UnsafeMutableRawPointer(acl)); acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text)
}
let aclBefore = aclText(keptPath)
check(aclBefore != nil, "an access list was set")
check(!tool("lp_append_to_page", ["path": "Kept.md", "content": "more"]).error, "the page is edited")
var keptInfo = stat()
stat(keptPath, &keptInfo)
check(keptInfo.st_flags & UInt32(UF_NODUMP) != 0, "the flag is kept")
check(keptInfo.st_gid == everyone, "the group is kept")
check(aclText(keptPath) == aclBefore, "the access list is kept")
check(read("Kept.md") == "kept\n\nmore\n", "and the text changed")

// A page protected against being replaced is left alone, and so is nothing else.
write("Guarded.md", "guarded\n")
let guardACL = Process()
guardACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
guardACL.arguments = ["+a", "everyone deny delete", root.appendingPathComponent("Guarded.md").path]
try! guardACL.run(); guardACL.waitUntilExit()
check(tool("lp_append_to_page", ["path": "Guarded.md", "content": "x"]).text.contains("protected"), "a page whose access list forbids replacing it is refused")
check(read("Guarded.md") == "guarded\n", "and keeps its text")
check(!allFiles().contains { ($0 as NSString).lastPathComponent.hasPrefix(".lp-mcp-") }, "and no temporary file is left behind")
let guardOff = Process()
guardOff.executableURL = URL(fileURLWithPath: "/bin/chmod")
guardOff.arguments = ["-a", "everyone deny delete", root.appendingPathComponent("Guarded.md").path]
try! guardOff.run(); guardOff.waitUntilExit()

// MARK: Review fixes (Codex round 6)

// A page with a second hard link outside the workspace: an edit never touches that other file.
write("Linked Twice.md", "original\n")
let twicePath = root.appendingPathComponent("Linked Twice.md").path
check(chflags(twicePath, UInt32(UF_NODUMP)) == 0, "a flag was set")
let otherLink = outside.appendingPathComponent("Other Link.md").path
check(link(twicePath, otherLink) == 0, "a second hard link was made outside")
check(!tool("lp_append_to_page", ["path": "Linked Twice.md", "content": "edited"]).error, "the page is edited")
var otherInfo = stat()
stat(otherLink, &otherInfo)
check(otherInfo.st_flags & UInt32(UF_NODUMP) != 0, "the other link keeps its flag")
check((try? String(contentsOfFile: otherLink, encoding: .utf8)) == "original\n", "and its text")
check(read("Linked Twice.md") == "original\n\nedited\n", "while the page has the edit")

// A folder made invisible through its Finder information.
write("Invisible/Plan.md", "invisible\n")
var finderInfo = [UInt8](repeating: 0, count: 32)
finderInfo[8] = 0x40
check(setxattr(root.appendingPathComponent("Invisible").path, "com.apple.FinderInfo", &finderInfo, 32, 0, 0) == 0, "Finder's invisible bit was set")
check(!(tool("lp_list_pages").json["pages"] as? [[String: Any]] ?? []).contains { ($0["path"] as? String)?.hasPrefix("Invisible") == true },
      "an invisible folder isn't listed")
check(tool("lp_read_page", ["path": "Invisible/Plan.md"]).text.contains("hidden"), "nor read by path")

// MARK: Review fixes (Codex round 7)

// An attachment nobody can read changes nothing: only Markdown files are ever opened.
write("Attachments/photo.jpg", "not really a photo")
chmod(root.appendingPathComponent("Attachments/photo.jpg").path, 0o000)
let withPhoto = tool("lp_list_pages")
check(withPhoto.json["incomplete"] as? Bool == false, "an unreadable attachment doesn't make the scan incomplete: \(withPhoto.json["incomplete"] ?? "?")")
let photoNote = tool("lp_daily_note", ["date": "2026-12-24"])
check(!photoNote.error && photoNote.json["created"] as? Bool == true, "and doesn't block a daily note: \(photoNote.text.prefix(120))")
chmod(root.appendingPathComponent("Attachments/photo.jpg").path, 0o644)

// MARK: Review fixes (Codex round 8)

// A folder whose Finder information can't be read: skipped, and the scan says it's incomplete.
write("Guarded Folder/2026-12-31.md", "the note\n")
let guardFolder = Process()
guardFolder.executableURL = URL(fileURLWithPath: "/bin/chmod")
guardFolder.arguments = ["+a", "everyone deny readextattr", root.appendingPathComponent("Guarded Folder").path]
try! guardFolder.run(); guardFolder.waitUntilExit()
check(tool("lp_list_pages").json["incomplete"] as? Bool == true, "an uninspectable folder makes the scan incomplete")
check(tool("lp_daily_note", ["date": "2026-12-31"]).text.contains("couldn’t be scanned"), "so its note isn't created twice")
let unguard = Process()
unguard.executableURL = URL(fileURLWithPath: "/bin/chmod")
unguard.arguments = ["-a", "everyone deny readextattr", root.appendingPathComponent("Guarded Folder").path]
try! unguard.run(); unguard.waitUntilExit()
check(tool("lp_daily_note", ["date": "2026-12-31"]).json["path"] as? String == "Guarded Folder/2026-12-31.md", "once readable, it's found")

// MARK: Review fixes (Codex round 9)

check(tool("lp_add_card", ["board": "Projects/Launch.md", "list": "Next", "title": "x"]).text.contains("“revision” is required"),
      "adding a card needs the board's revision")
let oldBoard = rev("Projects/Launch.md")
tool("lp_add_card", ["board": "Projects/Launch.md", "revision": oldBoard, "list": "Next", "title": "First"])
check(tool("lp_add_card", ["board": "Projects/Launch.md", "revision": oldBoard, "list": "Next", "title": "Second"]).text.contains("changed since"),
      "an old revision is refused, so a replaced board can't get the card")
check(tool("lp_search", ["query": "the"]).json["incomplete"] as? Bool == true, "search says it's incomplete when a page couldn't be read (Latin.md)")
check(tool("lp_list_tasks").json["incomplete"] as? Bool == true, "and so do tasks")

// MARK: A folder chosen inside a workspace

check(!choose(root.lastPathComponent, folder: "Projects").error, "a folder is chosen")
let scoped = (tool("lp_list_pages").json["pages"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
check(!scoped.isEmpty && scoped.allSatisfy { !$0.hasPrefix("Projects/") } && scoped.contains("Website Redesign.md"),
      "only its pages are listed, relative to it: \(scoped.prefix(4))")
check(tool("lp_read_page", ["path": "../Welcome.md"]).error, "nothing outside it can be read")
check(tool("lp_create_page", ["title": "Scoped"]).json["created"] as? String == "Scoped.md", "new pages go inside it")
check(exists("Projects/Scoped.md") && !exists("Scoped.md"), "really inside it")
check(choose(root.lastPathComponent, folder: ".lp").error, "a hidden folder can't be chosen")
check(!choose(second.lastPathComponent).error, "another workspace can be chosen")
check((tool("lp_list_pages").json["pages"] as? [Any])?.isEmpty == true, "and only its pages are seen")
check(!choose(root.lastPathComponent).error, "and back to the first")

// MARK: Nothing is ever deleted

let before = allFiles()
for _ in 0..<2 {
    tool("lp_create_page", ["title": "Welcome"])
    tool("lp_update_card", ["board": "Projects/Launch.md", "revision": rev("Projects/Launch.md"), "card": cardID, "move_to_list": "Backlog"])
    tool("lp_daily_note", ["append": "more"])
}
check(before.isSubset(of: allFiles()), "every file is still there: \(before.subtracting(allFiles()))")
check(read(".lp/boards/log.md") == "secret log\n" && read(".obsidian/workspace.md") == "settings\n", "hidden files are untouched")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
