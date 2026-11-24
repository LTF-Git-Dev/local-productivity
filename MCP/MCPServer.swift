//
//  MCPServer.swift
//  lp-mcp
//
//  The Model Context Protocol side: JSON-RPC 2.0 messages, one per line on stdin/stdout, and the
//  tools that call LPVault. `handle(_:)` turns one incoming line into the reply line (or none for
//  a notification), so the whole protocol is tested without a process.
//

import Foundation

nonisolated final class MCPServer {

    static let name = "lp"
    static let version = "1.0.0"
    /// Newest first; a client asking for one of these gets it, any other gets the newest.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// The workspaces this server may use, as set up when it was installed (`--workspace`, one or
    /// more). Claude can reach nothing else.
    struct AllowedWorkspace {
        let name: String
        let vault: LPVault
    }
    let workspaces: [AllowedWorkspace]
    /// The workspace — and folder inside it — the person chose for this session. Every tool but
    /// the two below refuses until there is one.
    private(set) var vault: LPVault?
    private(set) var scope: (workspace: String, folder: String)?
    /// What "today" means for daily notes and due dates; replaceable in tests.
    var today: () -> Day = { .today }
    /// Whether the Claude app can show the person a form (MCP elicitation) — then the person, not
    /// Claude, chooses the workspace. Set from the app's `initialize`.
    private(set) var clientCanAsk = false
    /// For apps without forms: let Claude pass on the person's choice from the chat (weaker — only
    /// with `--allow-choice-in-chat`).
    let allowChoiceInChat: Bool
    /// Sends a request to the Claude app and returns its answer (set by main; replaced in tests).
    var sendRequest: ((_ request: [String: Any]) -> [String: Any]?)?

    init(workspaces roots: [URL], allowChoiceInChat: Bool = false) throws {
        self.allowChoiceInChat = allowChoiceInChat
        guard !roots.isEmpty else { throw VaultError("No workspace was given: lp-mcp --workspace <folder> [--workspace <folder> …]") }
        var allowed: [AllowedWorkspace] = []
        for root in roots {
            let vault = try LPVault(root: root)
            guard !allowed.contains(where: { $0.vault.root == vault.root }) else { continue }
            var name = vault.root.lastPathComponent, counter = 2
            while allowed.contains(where: { $0.name.lowercased() == name.lowercased() }) { name = "\(vault.root.lastPathComponent) \(counter)"; counter += 1 }
            allowed.append(AllowedWorkspace(name: name, vault: vault))
        }
        workspaces = allowed
    }

    static let chooseFirst = """
    No workspace has been chosen for this session. Call lp_use_workspace: LP asks the person directly \
    which workspace — and which folder in it, if any — you may use. Don't guess or choose one yourself.
    """

    // MARK: - Messages

    func handle(_ line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return Self.encode(error: -32700, "Parse error: the message isn’t JSON.", id: NSNull())
        }
        guard let message = object as? [String: Any], message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else {
            // A reply from the client (to nothing this server asked) or something malformed.
            if let message = object as? [String: Any], message["method"] == nil, message["id"] != nil { return nil }
            return Self.encode(error: -32600, "Invalid request.", id: (object as? [String: Any])?["id"] ?? NSNull())
        }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        // Notifications (no id) never get an answer.
        guard let id, !(id is NSNull) else { return nil }
        // Ids are text or numbers — not true/false, which JSON also reads as a number here.
        guard id is String || (id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true else {
            return Self.encode(error: -32600, "Invalid request id.", id: NSNull())
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            let capabilities = params["capabilities"] as? [String: Any] ?? [:]
            clientCanAsk = (capabilities["elicitation"] as? [String: Any]).map { $0.isEmpty || $0["form"] != nil } ?? false
            return Self.encode(result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.name, "title": "LP", "version": Self.version],
                "instructions": Self.instructions,
            ], id: id)
        case "ping":
            return Self.encode(result: [String: Any](), id: id)
        case "tools/list":
            return Self.encode(result: ["tools": Self.tools.map(\.json)], id: id)
        case "tools/call":
            guard let name = params["name"] as? String else { return Self.encode(error: -32602, "tools/call needs a tool name.", id: id) }
            guard let tool = Self.tools.first(where: { $0.name == name }) else {
                return Self.encode(error: -32602, "There’s no tool called “\(name)”.", id: id)
            }
            if let given = params["arguments"], !(given is [String: Any]) {
                return Self.encode(error: -32602, "A tool's arguments must be an object.", id: id)
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            // Arguments the tool doesn't have are refused rather than ignored (a misspelt one would
            // otherwise silently do nothing) — as a tool error, so the model can correct itself.
            let unknown = arguments.keys.filter { tool.properties[$0] == nil }.sorted()
            if !unknown.isEmpty {
                let text = "\(name) has no argument \(unknown.map { "“\($0)”" }.joined(separator: ", ")). It takes: \(tool.properties.keys.sorted().joined(separator: ", "))."
                return Self.encode(result: ["content": [["type": "text", "text": text]], "isError": true], id: id)
            }
            currentRequestID = id
            defer { currentRequestID = nil }
            do {
                return Self.encode(result: ["content": [["type": "text", "text": try call(name, Arguments(arguments))]], "isError": false], id: id)
            } catch is Cancelled {
                return nil   // a cancelled request gets no answer
            } catch {
                return Self.encode(result: ["content": [["type": "text", "text": "\(error)"]], "isError": true], id: id)
            }
        default:
            return Self.encode(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    static func encode(result: Any, id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func encode(error code: Int, _ message: String, id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    static func line(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A tool's answer as readable JSON.
    static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Shows the person a form in the Claude app: which allowed workspace, and optionally which
    /// folder. Only their own answer counts; declining or closing it chooses nothing.
    func askPerson(suggested: (String?, String?), _ sendRequest: ([String: Any]) -> [String: Any]?) throws -> (workspace: String, folder: String) {
        var message = "Claude wants to work with your LP notes. Which workspace may it read and change in this conversation?"
        if let workspace = suggested.0 {
            message += " (Claude suggested “\(workspace)”\(suggested.1.map { ", folder “\($0)”" } ?? "").)"
        }
        let request: [String: Any] = ["method": "elicitation/create", "params": [
            "message": message,
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "workspace": ["type": "string", "title": "Workspace", "enum": workspaces.map(\.name),
                                  "description": "The LP workspace Claude may use in this conversation."],
                    "folder": ["type": "string", "title": "Folder (optional)",
                               "description": "Limit Claude to one folder inside it, like Projects. Leave empty to allow the whole workspace."],
                ],
                "required": ["workspace"],
            ],
        ]]
        guard let reply = sendRequest(request) else { throw VaultError("The person wasn’t asked (no answer came back), so no workspace was chosen.") }
        if reply["cancelled"] as? Bool == true { throw Cancelled() }
        guard let result = reply["result"] as? [String: Any] else {
            throw VaultError("The Claude app couldn’t show the choice (\(((reply["error"] as? [String: Any])?["message"] as? String) ?? "no reason given")), so no workspace was chosen.")
        }
        guard result["action"] as? String == "accept", let content = result["content"] as? [String: Any],
              let workspace = content["workspace"] as? String else {
            throw VaultError("The person didn’t choose a workspace (\(result["action"] as? String ?? "no answer")), so nothing in LP was used. Ask them if they’d like to choose one.")
        }
        // An absent or empty folder is the whole workspace (as the form says); anything else must be text.
        if let folder = content["folder"], !(folder is String) {
            throw VaultError("The answer’s folder wasn’t text, so no workspace was chosen.")
        }
        return (workspace, (content["folder"] as? String) ?? "")
    }

    /// The tool call was cancelled by the Claude app while the person was being asked.
    struct Cancelled: Error {}

    /// The id of the request being handled (so a cancellation for it can be recognised).
    private(set) var currentRequestID: Any?

    /// Whether two JSON-RPC ids are the same id: 7 and "7" are different.
    static func sameID(_ a: Any?, _ b: Any?) -> Bool {
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? NSNumber, let b = b as? NSNumber, !(a is String), !(b is String) {
            return CFGetTypeID(a) != CFBooleanGetTypeID() && CFGetTypeID(b) != CFBooleanGetTypeID() && a == b
        }
        return false
    }

    // MARK: - Arguments

    struct Arguments {
        let values: [String: Any]
        init(_ values: [String: Any]) { self.values = values }

        func string(_ key: String) throws -> String {
            guard let value = values[key] as? String else { throw VaultError("“\(key)” is required (text).") }
            return value
        }
        func optionalString(_ key: String) throws -> String? {
            guard let value = values[key], !(value is NSNull) else { return nil }
            guard let text = value as? String else { throw VaultError("“\(key)” must be text.") }
            return text
        }
        func bool(_ key: String) throws -> Bool {
            guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw VaultError("“\(key)” is required (true or false).")
            }
            return value.boolValue
        }
        func optionalBool(_ key: String) throws -> Bool? {
            guard values[key] != nil, !(values[key] is NSNull) else { return nil }
            return try bool(key)
        }
        func optionalInt(_ key: String) throws -> Int? {
            guard let value = values[key], !(value is NSNull) else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1_000_000 else {
                throw VaultError("“\(key)” must be a whole number.")
            }
            return number.intValue
        }
        func optionalStrings(_ key: String) throws -> [String]? {
            guard let value = values[key], !(value is NSNull) else { return nil }
            guard let list = value as? [String] else { throw VaultError("“\(key)” must be a list of text.") }
            return list
        }
    }

    /// "today", "tomorrow", "yesterday" or YYYY-MM-DD.
    func day(_ text: String) throws -> Day {
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "today": return today()
        case "tomorrow": return today().adding(days: 1)
        case "yesterday": return today().adding(days: -1)
        default:
            // Day doesn't check the calendar: 2026-02-30 must come back as itself from a real date.
            guard let day = Day(iso: text.trimmingCharacters(in: .whitespaces)), Day(day.date()) == day,
                  text.trimmingCharacters(in: .whitespaces) == day.iso else {
                throw VaultError("“\(text)” isn’t a date. Use YYYY-MM-DD, today, tomorrow or yesterday.")
            }
            return day
        }
    }

    /// HH:MM, 24-hour.
    static func time(_ text: String) throws -> TimeOfDay {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw VaultError("“\(text)” isn’t a time. Use 24-hour HH:MM, like 14:30.")
        }
        return TimeOfDay(hour: hour, minute: minute)
    }

    static func iso(_ time: TimeOfDay?) -> Any {
        time.map { String(format: "%02d:%02d", $0.hour, $0.minute) } ?? NSNull()
    }

    // MARK: - Tools

    func call(_ name: String, _ a: Arguments) throws -> String {
        switch name {
        case "lp_list_workspaces":
            // Before the person has chosen, nothing about the workspaces is shown — not even names.
            guard let scope, let vault else {
                return Self.json(["chosen": NSNull(), "allowed": workspaces.count,
                                  "note": "Call lp_use_workspace: LP asks the person directly which workspace and folder you may use."])
            }
            return Self.json(["chosen": ["workspace": scope.workspace, "folder": scope.folder.isEmpty ? NSNull() : scope.folder as Any],
                              "folders": (try? vault.files.subfolders("")) ?? []])

        case "lp_use_workspace":
            let suggested = (try a.optionalString("workspace"), try a.optionalString("folder"))
            // A new choice starts from nothing: declining it, or any failure, leaves no workspace in use.
            vault = nil
            scope = nil
            let choice: (workspace: String, folder: String)
            if clientCanAsk, let sendRequest {
                choice = try askPerson(suggested: suggested, sendRequest)
            } else if allowChoiceInChat {
                guard let workspace = suggested.0 else {
                    throw VaultError("Ask the person which workspace (and folder) to use, then pass their answer as workspace and folder.")
                }
                choice = (workspace, suggested.1 ?? "")
            } else {
                throw VaultError("This Claude app can’t show the person a form to choose a workspace, so LP can’t be used here. (Started with --allow-choice-in-chat, Claude may pass on the person's choice from the chat instead.)")
            }
            // Exactly a name that was offered.
            guard let workspace = workspaces.first(where: { $0.name == choice.workspace }) else {
                throw VaultError("“\(choice.workspace)” isn’t an allowed workspace, so nothing was chosen.")
            }
            let folder = try workspace.vault.folder(choice.folder)
            // Opened once and checked (there, no link, not hidden); the chosen folder's vault keeps
            // that very handle, so it can't be redirected later.
            let handle = try workspace.vault.files.openFolder(folder)
            if folder.isEmpty {
                close(handle)
                vault = workspace.vault
            } else {
                vault = LPVault(files: AnchoredFiles(adopting: handle), root: workspace.vault.root.appendingPathComponent(folder))
            }
            scope = (workspace.name, folder)
            return Self.json(["using": ["workspace": workspace.name, "folder": folder.isEmpty ? NSNull() : folder as Any],
                              "note": folder.isEmpty ? "The person allowed the whole workspace; paths are relative to it."
                                  : "The person allowed only “\(folder)”; nothing outside it can be used, and paths are relative to it."])
        default:
            break
        }
        guard let vault else { throw VaultError(Self.chooseFirst) }
        switch name {
        case "lp_list_pages":
            let pages = try vault.pages(in: try a.optionalString("folder") ?? "")
            let formatter = ISO8601DateFormatter()
            return Self.json(["count": pages.count, "incomplete": vault.lastScanIncomplete, "pages": pages.map {
                ["path": $0.path, "title": $0.title, "kind": $0.isBoard ? "board" : "page", "modified": formatter.string(from: $0.modified)]
            }])

        case "lp_search":
            let hits = try vault.search(try a.string("query"), limit: try a.optionalInt("limit") ?? 20)
            return Self.json(["count": hits.count, "incomplete": vault.lastScanIncomplete, "results": hits.map { ["path": $0.path, "title": $0.title, "snippet": $0.snippet] }])

        case "lp_read_page":
            let page = try vault.readPage(try a.string("path"))
            return Self.json(["path": page.path, "kind": page.isBoard ? "board" : "page", "revision": page.revision, "content": page.text])

        case "lp_list_tasks":
            let filter = try a.optionalString("status").map { raw -> LPVault.TaskFilter in
                guard let value = LPVault.TaskFilter(rawValue: raw.lowercased()) else { throw VaultError("“status” is open, done or all.") }
                return value
            } ?? .open
            let dueBy = try a.optionalString("due_by").map { try day($0) }
            let tasks = try vault.tasks(filter, dueBy: dueBy, in: try a.optionalString("folder") ?? "")
            let now = today()
            return Self.json(["today": now.iso, "count": tasks.count, "incomplete": vault.lastScanIncomplete, "tasks": tasks.map { task -> [String: Any] in
                var item: [String: Any] = ["path": task.path, "text": task.text, "done": task.isDone,
                                           "due": task.due.map { $0.iso as Any } ?? NSNull(), "time": Self.iso(task.time),
                                           "overdue": !task.isDone && (task.due.map { $0 < now } ?? false)]
                if let ordinal = task.ordinal { item["ordinal"] = ordinal }
                item["revision"] = task.revision
                if let list = task.list { item["board_list"] = list; item["card"] = task.cardID ?? task.text }
                return item
            }])

        case "lp_list_boards":
            let now = today()
            let boards = try vault.boards(in: try a.optionalString("folder") ?? "")
            return Self.json(["today": now.iso, "count": boards.count, "incomplete": vault.lastScanIncomplete, "boards": boards.map { board -> [String: Any] in
                ["path": board.path, "title": board.title, "cards": board.summary.total, "done": board.summary.done,
                 "percent_done": board.summary.percent, "overdue": board.summary.overdue(on: now),
                 "due_soon": board.summary.dueSoon(on: now),
                 "lists": board.summary.lists.map { ["title": $0.title, "cards": $0.count, "counts_as_done": $0.marksComplete] }]
            }])

        case "lp_read_board":
            let (path, board, revision) = try vault.readBoard(try a.string("path"))
            let summary = BoardSummary(board: board)
            let now = today()
            return Self.json([
                "path": path, "revision": revision, "board_id": board.boardID.map { $0 as Any } ?? NSNull(),
                "progress": ["cards": summary.total, "done": summary.done, "percent_done": summary.percent,
                             "overdue": summary.overdue(on: now), "due_soon": summary.dueSoon(on: now)],
                "lists": board.lanes.map { lane -> [String: Any] in
                    ["title": lane.title, "counts_as_done": lane.marksComplete, "cards": lane.cards.map { card -> [String: Any] in
                        ["id": card.hasStoredID ? card.id : NSNull(), "title": card.title.isEmpty ? "Untitled card" : card.title,
                         "done": card.isDone || lane.marksComplete, "due": card.due.map { $0.iso as Any } ?? NSNull(),
                         "time": Self.iso(CardText.dueTime(in: card.text)), "tags": card.tags, "notes": card.body]
                    }]
                },
            ])

        case "lp_create_page":
            let page = try vault.createPage(title: try a.string("title"), in: try a.optionalString("folder") ?? "",
                                            content: try a.optionalString("content") ?? "")
            return Self.json(["created": page.path, "revision": page.revision])

        case "lp_append_to_page":
            let page = try vault.append(to: try a.string("path"), markdown: try a.string("content"))
            return Self.json(["updated": page.path, "revision": page.revision])

        case "lp_replace_text":
            let page = try vault.replaceText(in: try a.string("path"), find: try a.string("find"), with: try a.string("replace_with"))
            return Self.json(["updated": page.path, "revision": page.revision])

        case "lp_update_page":
            let page = try vault.replacePage(try a.string("path"), content: try a.string("content"), revision: try a.string("revision"))
            return Self.json(["updated": page.path, "revision": page.revision])

        case "lp_daily_note":
            let date = try day(try a.optionalString("date") ?? "today")
            let note = try vault.dailyNote(for: date, folder: try a.optionalString("folder"))
            if let addition = try a.optionalString("append"), !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try vault.append(to: note.path, markdown: addition)
            }
            let page = try vault.readPage(note.path)
            return Self.json(["path": note.path, "created": note.created, "revision": page.revision, "content": page.text])

        case "lp_set_task_done":
            let outcome = try vault.setTaskDone(in: try a.string("path"), text: try a.string("task"),
                                                ordinal: try a.optionalInt("ordinal"),
                                                due: try a.optionalString("due").map { try day($0) },
                                                time: try a.optionalString("time").map { try Self.time($0) },
                                                revision: try a.string("revision"), done: try a.bool("done"))
            return Self.json(["result": outcome.result, "revision": outcome.revision])

        case "lp_create_board":
            let created = try vault.createBoard(title: try a.string("title"), in: try a.optionalString("folder") ?? "",
                                                template: try a.optionalString("template") ?? "simple")
            let (_, board, revision) = try vault.readBoard(created.path)
            return Self.json(["created": created.path, "revision": revision, "lists": board.lanes.map(\.title)])

        case "lp_add_card":
            let added = try vault.addCard(to: try a.string("board"), list: try a.string("list"), title: try a.string("title"),
                                       due: try a.optionalString("due").map { try day($0) },
                                       time: try a.optionalString("time").map { try Self.time($0) },
                                       tags: try a.optionalStrings("tags") ?? [], notes: try a.optionalString("notes") ?? "",
                                       revision: try a.string("revision"))
            return Self.json(["added": added.id, "revision": added.revision])

        case "lp_update_card":
            var change = LPVault.CardChange()
            change.title = try a.optionalString("title")
            change.tags = try a.optionalStrings("tags")
            if let due = try a.optionalString("due") {
                change.changesDue = true
                change.due = due.isEmpty ? nil : try day(due)
            }
            if let time = try a.optionalString("time") {
                change.changesTime = true
                change.time = time.isEmpty ? nil : try Self.time(time)
            }
            change.notes = try a.optionalString("notes")
            change.done = try a.optionalBool("done")
            change.moveTo = try a.optionalString("move_to_list")
            change.before = try a.optionalString("before_card")
            let hasChange = change.title != nil || change.tags != nil || change.changesDue || change.changesTime
                || change.notes != nil || change.done != nil || change.moveTo != nil
            guard hasChange else { throw VaultError("Say what to change: title, due, time, tags, notes, done or move_to_list.") }
            let outcome = try vault.updateCard(on: try a.string("board"), card: try a.string("card"), change,
                                               revision: try a.string("revision"))
            return Self.json(["result": outcome.result, "revision": outcome.revision])

        default:
            throw VaultError("There’s no tool called “\(name)”.")
        }
    }

    // MARK: - Tool list

    struct Tool {
        let name: String
        let title: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]
        let readOnly: Bool
        let idempotent: Bool
        /// It can replace or remove text that is there now (a page's text, a card's notes).
        var destructive = false

        var json: [String: Any] {
            ["name": name, "title": title, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                             "idempotentHint": idempotent, "openWorldHint": false]]
        }
    }

    static func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    static let pathText = "Path inside the workspace, e.g. \"Projects/Plan.md\" (from lp_list_pages or lp_search)."

    static let instructions = """
    LP is a Mac app whose notes, tasks and Kanban boards are plain Markdown files in one folder (the workspace). \
    Before reading or changing anything, call lp_use_workspace: LP then asks the person directly which workspace — \
    and which folder in it, if any — you may use. Never guess or pick one yourself; to switch, call it again. \
    These tools read and change those files directly, the way LP does; LP shows the changes when it's open. \
    Paths are relative to the workspace. Nothing can be deleted. Boards are changed card by card \
    (lp_add_card, lp_update_card) so they stay valid; pages with lp_append_to_page, lp_replace_text or lp_update_page. \
    Dates are YYYY-MM-DD (or today/tomorrow/yesterday), times 24-hour HH:MM.
    """

    static let tools: [Tool] = [
        Tool(name: "lp_list_workspaces", title: "List workspaces",
             description: "Says which workspace (and folder) the person chose for this session, and the folders at its top. Before a choice it shows nothing about the workspaces: call lp_use_workspace.",
             properties: [:], required: [], readOnly: true, idempotent: true),
        Tool(name: "lp_use_workspace", title: "Use a workspace",
             description: "Asks the person — directly, in a form — which workspace and which folder in it, if any, you may use in this conversation. Every other tool works only after they've chosen, and only inside what they chose; paths are then relative to it. Call it again to switch.",
             properties: ["workspace": text("Optional: a workspace to suggest (the person still chooses)."),
                          "folder": text("Optional: a folder to suggest (the person still chooses).")],
             required: [], readOnly: false, idempotent: false),
        Tool(name: "lp_list_pages", title: "List pages",
             description: "Lists every page and board in the workspace (or one folder), with its kind and when it last changed.",
             properties: ["folder": text("Only this folder and its subfolders, e.g. \"Projects\". Default: everything.")],
             required: [], readOnly: true, idempotent: true),
        Tool(name: "lp_search", title: "Search pages",
             description: "Finds pages whose name or text contains every word of the query (case and accents ignored), name matches first, with a snippet.",
             properties: ["query": text("Words to look for."),
                          "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Most results to return (default 20)."]],
             required: ["query"], readOnly: true, idempotent: true),
        Tool(name: "lp_read_page", title: "Read a page",
             description: "Returns a page's full Markdown and its revision (needed by lp_update_page). Works for boards too (raw Kanban Markdown); prefer lp_read_board for those.",
             properties: ["path": text(pathText)], required: ["path"], readOnly: true, idempotent: true),
        Tool(name: "lp_list_tasks", title: "List tasks",
             description: "Lists to-dos from every page and cards from every board, as LP's Home does — open ones by default, soonest due first. Board cards include their list and card reference.",
             properties: ["status": ["type": "string", "enum": ["open", "done", "all"], "description": "Which tasks (default open)."],
                          "due_by": text("Only tasks due on or before this date (YYYY-MM-DD, today, tomorrow)."),
                          "folder": text("Only pages in this folder.")],
             required: [], readOnly: true, idempotent: true),
        Tool(name: "lp_list_boards", title: "List boards",
             description: "Lists every Kanban board with its progress: cards, done, percent done, overdue, due within 3 days, and its lists.",
             properties: ["folder": text("Only boards in this folder.")], required: [], readOnly: true, idempotent: true),
        Tool(name: "lp_read_board", title: "Read a board",
             description: "Returns a board's lists and cards (id, title, done, due, time, tags, notes) and its progress. A card whose id is null has none stored yet: refer to it by its title; it gets an id when the board is next changed.",
             properties: ["path": text(pathText)], required: ["path"], readOnly: true, idempotent: true),
        Tool(name: "lp_create_page", title: "Create a page",
             description: "Creates a new page named after the title (never replaces one: \"Plan 2\" if \"Plan\" exists). Creates the folder if needed.",
             properties: ["title": text("The page's name (its file name)."), "folder": text("Folder to put it in (default: the workspace's top)."),
                          "content": text("Markdown for the page (optional).")],
             required: ["title"], readOnly: false, idempotent: false),
        Tool(name: "lp_append_to_page", title: "Add to a page",
             description: "Adds Markdown at the end of a page, after a blank line. Not for boards.",
             properties: ["path": text(pathText), "content": text("Markdown to add, e.g. \"- [ ] Call the printer 📅 2026-11-25\".")],
             required: ["path", "content"], readOnly: false, idempotent: false),
        Tool(name: "lp_replace_text", title: "Edit text on a page",
             description: "Replaces one exact passage of a page with new text. The passage must appear exactly once (include more of it if needed). Not for boards.",
             properties: ["path": text(pathText), "find": text("The exact text now on the page."), "replace_with": text("What to put instead (may be empty).")],
             required: ["path", "find", "replace_with"], readOnly: false, idempotent: false, destructive: true),
        Tool(name: "lp_update_page", title: "Rewrite a page",
             description: "Replaces a page's whole Markdown. Needs the revision from lp_read_page, and refuses if the page changed since — read it again then. Not for boards. Prefer lp_replace_text for small edits.",
             properties: ["path": text(pathText), "content": text("The page's complete new Markdown."), "revision": text("The revision lp_read_page returned.")],
             required: ["path", "content", "revision"], readOnly: false, idempotent: false, destructive: true),
        Tool(name: "lp_daily_note", title: "Daily note",
             description: "Opens the daily note for a date (named like 2026-11-24, found anywhere in the workspace), creating it if needed — in \"Daily Notes\" when that folder exists — optionally adding Markdown to it. Returns its content.",
             properties: ["date": text("YYYY-MM-DD, today (default), tomorrow or yesterday."),
                          "folder": text("Where to create it if it doesn't exist (default: \"Daily Notes\" if present, else the top)."),
                          "append": text("Markdown to add at the end (optional).")],
             required: [], readOnly: false, idempotent: false),
        Tool(name: "lp_set_task_done", title: "Tick off a task",
             description: "Marks a task done or open again. On a page, `task` is the task's text as lp_list_tasks shows it (pass `ordinal` too if two read the same). On a board, `task` is the card's id or title; reopening a card in a list that counts as done moves it back to the first open list.",
             properties: ["path": text(pathText), "task": text("The task's text (pages) or the card's id or title (boards)."),
                          "ordinal": ["type": "integer", "minimum": 0, "description": "The task's ordinal from lp_list_tasks (pages only, optional)."],
                          "due": text("The task's due date from lp_list_tasks, if it has one (pages only) — tells look-alike tasks apart."),
                          "time": text("The task's due time (HH:MM) from lp_list_tasks, if it has one (pages only)."),
                          "revision": text("The page's (or board's) revision from lp_list_tasks, lp_read_page or lp_read_board. Refused if it changed since: list or read it again."),
                          "done": ["type": "boolean", "description": "true to tick it off, false to reopen it."]],
             required: ["path", "task", "revision", "done"], readOnly: false, idempotent: true),
        Tool(name: "lp_create_board", title: "Create a board",
             description: "Creates a Kanban board from one of LP's templates: simple (To do, In progress, Done), project, weekly, content or bugs. The last list counts its cards as done.",
             properties: ["title": text("The board's name."), "folder": text("Folder to put it in."),
                          "template": ["type": "string", "enum": ["simple", "project", "weekly", "content", "bugs"], "description": "Default simple."]],
             required: ["title"], readOnly: false, idempotent: false),
        Tool(name: "lp_add_card", title: "Add a card",
             description: "Adds a card at the end of a board's list. Returns the new card's id.",
             properties: ["board": text("The board's path."), "list": text("The list's title (case ignored)."), "title": text("The card's title."),
                          "revision": text("The board's revision from lp_read_board or lp_create_board, or from the last card change. Refused if the board changed since: read it again."),
                          "due": text("Due date (YYYY-MM-DD, today, tomorrow)."), "time": text("Due time, 24-hour HH:MM (with a due date)."),
                          "tags": ["type": "array", "items": ["type": "string"], "description": "Tags, without #."],
                          "notes": text("Notes shown inside the card (Markdown).")],
             required: ["board", "list", "title", "revision"], readOnly: false, idempotent: false),
        Tool(name: "lp_update_card", title: "Update or move a card",
             description: "Changes a card — title, due date or time (empty text clears it), tags, notes, done — and/or moves it to another list (moving into a list that counts as done marks it done; out of one, open). Only what's given changes.",
             properties: ["board": text("The board's path."), "card": text("The card's id (from lp_read_board) or its exact title."),
                          "revision": text("The board's revision from lp_read_board, or from the last lp_add_card / lp_update_card result. Refused if the board changed since: read it again."),
                          "title": text("New title."), "due": text("New due date, or empty text to remove it."),
                          "time": text("New due time HH:MM, or empty text to remove it."),
                          "tags": ["type": "array", "items": ["type": "string"], "description": "Replaces the card's tags."],
                          "notes": text("Replaces the card's notes."), "done": ["type": "boolean", "description": "Mark done or open."],
                          "move_to_list": text("Title of the list to move it to."),
                          "before_card": text("With move_to_list: put it before this card (id or title); default at the end.")],
             required: ["board", "card", "revision"], readOnly: false, idempotent: false, destructive: true),
    ]
}
