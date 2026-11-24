//
//  main.swift
//  lp-mcp
//
//  LP's MCP server: lets Claude (Claude Code, Claude Desktop) read and change the pages, tasks and
//  boards of the LP workspaces it's given — the one the person chooses each session. Speaks MCP over stdio: one JSON message per line in, one out.
//  Usage: lp-mcp --workspace <folder> [--workspace <folder> …]   (or LP_WORKSPACE=<folder>)
//

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lp-mcp: \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") { print("lp-mcp \(MCPServer.version)"); exit(0) }
if arguments.contains("--help") || arguments.contains("-h") {
    print("Usage: lp-mcp --workspace <folder> [--workspace <folder> …]\nLP's MCP server for Claude: Claude asks you which of these workspaces (and folder) to use, then reads and changes its pages, tasks and boards.")
    exit(0)
}
// One or more workspaces Claude may be given (it asks the person which one to use each session).
var roots: [String] = []
var allowChoiceInChat = false
var index = 0
while index < arguments.count {
    if arguments[index] == "--allow-choice-in-chat" {
        allowChoiceInChat = true
        index += 1
    } else if arguments[index] == "--workspace" {
        guard arguments.indices.contains(index + 1) else { fail("--workspace needs a folder.") }
        roots.append(arguments[index + 1])
        index += 2
    } else {
        fail("unknown option \(arguments[index]). Usage: lp-mcp --workspace <folder> [--workspace <folder> …]")
    }
}
if roots.isEmpty, let fromEnvironment = ProcessInfo.processInfo.environment["LP_WORKSPACE"], !fromEnvironment.isEmpty {
    roots = [fromEnvironment]
}
guard !roots.isEmpty else { fail("say which LP workspaces Claude may use: lp-mcp --workspace <folder> [--workspace <folder> …]") }

let server: MCPServer
do {
    server = try MCPServer(workspaces: roots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                           allowChoiceInChat: allowChoiceInChat)
} catch {
    fail("\(error)")
}
FileHandle.standardError.write(Data("lp-mcp \(MCPServer.version): may use \(server.workspaces.map(\.name).joined(separator: ", "))\n".utf8))
func send(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

// Requests this server sends the Claude app (asking the person to choose a workspace): the answer
// is read here; anything else that arrives meanwhile is handled after it, in order.
var pending: [String] = []
var asked = 0
server.sendRequest = { request in
    asked += 1
    let id = "lp-ask-\(asked)"
    var message = request
    message["jsonrpc"] = "2.0"
    message["id"] = id
    send(MCPServer.line(message))
    while let line = readLine(strippingNewline: true) {
        let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        if let message, message["method"] == nil, message["id"] as? String == id {
            return message
        }
        // The tool call that is asking was cancelled: stop waiting (the form may never be answered).
        if let message, message["method"] as? String == "notifications/cancelled",
           MCPServer.sameID((message["params"] as? [String: Any])?["requestId"], server.currentRequestID) {
            return ["cancelled": true]
        }
        pending.append(line)
    }
    return nil
}

// stdout carries only protocol messages, one per line.
while let line = pending.isEmpty ? readLine(strippingNewline: true) : pending.removeFirst() {
    autoreleasepool {
        if let reply = server.handle(line) { send(reply) }
    }
}
