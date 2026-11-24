//
//  main.swift
//  lp-mcp
//
//  LP's MCP server: lets Claude (Claude Code, Claude Desktop) read and change the pages, tasks and
//  boards of one LP workspace. Speaks MCP over stdio: one JSON message per line in, one out.
//  Usage: lp-mcp --workspace <folder>   (or LP_WORKSPACE=<folder>)
//

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lp-mcp: \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") { print("lp-mcp \(MCPServer.version)"); exit(0) }
if arguments.contains("--help") || arguments.contains("-h") {
    print("Usage: lp-mcp --workspace <folder>\nLP's MCP server for Claude: reads and changes the pages, tasks and boards in that folder.")
    exit(0)
}
var workspace = ProcessInfo.processInfo.environment["LP_WORKSPACE"]
if let index = arguments.firstIndex(of: "--workspace") {
    guard arguments.indices.contains(index + 1) else { fail("--workspace needs a folder.") }
    workspace = arguments[index + 1]
}
guard let workspace, !workspace.isEmpty else { fail("say which LP workspace to use: lp-mcp --workspace <folder>") }

let vault: LPVault
do {
    vault = try LPVault(root: URL(fileURLWithPath: (workspace as NSString).expandingTildeInPath))
} catch {
    fail("\(error)")
}

let server = MCPServer(vault: vault)
FileHandle.standardError.write(Data("lp-mcp \(MCPServer.version): serving \(vault.root.path)\n".utf8))
// stdout carries only protocol messages, one per line.
while let line = readLine(strippingNewline: true) {
    autoreleasepool {
        if let reply = server.handle(line) {
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }
}
