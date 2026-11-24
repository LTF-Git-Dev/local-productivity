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
var index = 0
while index < arguments.count {
    if arguments[index] == "--workspace" {
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
    server = try MCPServer(workspaces: roots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
} catch {
    fail("\(error)")
}
FileHandle.standardError.write(Data("lp-mcp \(MCPServer.version): may use \(server.workspaces.map(\.name).joined(separator: ", "))\n".utf8))
// stdout carries only protocol messages, one per line.
while let line = readLine(strippingNewline: true) {
    autoreleasepool {
        if let reply = server.handle(line) {
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }
}
