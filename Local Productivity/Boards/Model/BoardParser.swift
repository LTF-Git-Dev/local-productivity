//
//  BoardParser.swift
//  LP
//
//  Reads and writes board files. Writing produces the layout Obsidian's Kanban plugin
//  produces, so a board saved by either app reads back unchanged in the other, and
//  anything LP does not understand is carried through untouched.
//

import Foundation

nonisolated enum BoardParser {

    /// True for a Markdown file whose front matter marks it as a board.
    static func isBoard(_ text: String) -> Bool {
        guard text.hasPrefix("---") else { return false }
        let head = text.prefix(600)
        return head.contains("kanban-plugin:")
    }

    // MARK: Reading

    static func parse(_ input: String) -> Board {
        var text = input.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var lines = text.components(separatedBy: "\n")

        // Front matter.
        var frontMatter = ""
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) {
            frontMatter = lines[1..<close].joined(separator: "\n")
            lines.removeSubrange(0...close)
        }

        // The settings block at the end.
        var settingsBlock: String? = nil
        if let start = lines.lastIndex(where: { $0.hasPrefix("%% kanban:settings") }) {
            var end = lines.count - 1
            while end > start, lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            settingsBlock = lines[start...end].joined(separator: "\n")
            lines.removeSubrange(start...)
        }

        var preamble: [String] = []
        var lanes: [BoardLane] = []
        var archive: [BoardCard] = []
        var inArchive = false
        var sawArchiveRule = false
        var currentLane: BoardLane? = nil
        var currentCard: BoardCard? = nil
        var pendingBlank = 0
        var archiveLines: [String] = []
        var seenIDs = Set<String>()

        func finishCard() {
            guard var card = currentCard else { return }
            card.body = card.body.trimmingCharacters(in: .newlines)
            if inArchive {
                archive.append(card)
            } else {
                currentLane?.cards.append(card)
            }
            currentCard = nil
        }

        func finishLane() {
            finishCard()
            if let lane = currentLane, !inArchive {
                lanes.append(lane)
            }
            currentLane = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")

            if line.hasPrefix("## ") {
                finishLane()
                let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if sawArchiveRule, title.lowercased() == "archive" {
                    inArchive = true
                } else {
                    inArchive = false
                }
                currentLane = BoardLane(id: "lane-\(lanes.count)-\(UUID().uuidString.prefix(6))", title: title,
                                        marksComplete: false, cards: [])
                pendingBlank = 0
                continue
            }
            // The rule before the archive. An indented "---" is part of a card's notes.
            if !isIndented, trimmed == "***" || trimmed == "---" {
                finishLane()
                sawArchiveRule = true
                continue
            }
            if trimmed == "**Complete**", !inArchive, currentLane != nil, currentCard == nil, currentLane?.cards.isEmpty == true {
                currentLane?.marksComplete = true
                continue
            }
            if let (isDone, rest) = cardStart(line), currentLane != nil {
                finishCard()
                let (body, id) = splitBlockID(rest)
                // A card copied together with its block ID would share it with the original and the
                // two would act as one; the copy gets its own ID, written the next time LP saves.
                let stored = id.flatMap { seenIDs.insert($0).inserted ? $0 : nil }
                currentCard = BoardCard(id: stored ?? BoardIDs.newCardID(), text: body, body: "", isDone: isDone,
                                        hasStoredID: stored != nil)
                pendingBlank = 0
                continue
            }
            if currentCard != nil {
                if trimmed.isEmpty {
                    pendingBlank += 1
                    continue
                }
                // Indented lines under a card are its notes.
                if line.hasPrefix("\t") || line.hasPrefix("  ") {
                    let content = line.hasPrefix("\t") ? String(line.dropFirst()) : dedent(line)
                    if currentCard?.body.isEmpty == false {
                        currentCard?.body += String(repeating: "\n", count: pendingBlank + 1)
                    }
                    currentCard?.body += content
                    pendingBlank = 0
                    continue
                }
                finishCard()
            }
            if trimmed.isEmpty {
                pendingBlank += 1
                continue
            }
            if inArchive, currentLane != nil {
                archiveLines.append(line)
            } else if currentLane?.cards.isEmpty == true {
                currentLane?.leadingLines.append(line)
            } else if currentLane != nil {
                currentLane?.extraLines.append(line)
            } else {
                preamble.append(line)
            }
            pendingBlank = 0
        }
        finishLane()

        return Board(frontMatter: frontMatter, lanes: lanes, archive: archive, settingsBlock: settingsBlock,
                     preamble: preamble.joined(separator: "\n"), archiveLines: archiveLines)
    }

    /// `- [ ] text` or `- [x] text`, returning whether it is done and the text.
    private static func cardStart(_ line: String) -> (Bool, String)? {
        guard line.hasPrefix("- [") , line.count >= 5 else { return nil }
        let characters = Array(line.prefix(6))
        guard characters.count >= 5, characters[4] == "]" else { return nil }
        let status = characters[3]
        guard status == " " || status == "x" || status == "X" else { return nil }
        let rest = line.dropFirst(5).drop(while: { $0 == " " })
        return (status != " ", String(rest))
    }

    /// Separates a trailing Obsidian block ID (` ^abc-123`) from the card text.
    private static func splitBlockID(_ text: String) -> (String, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let caret = trimmed.lastIndex(of: "^"), caret > trimmed.startIndex,
              trimmed[trimmed.index(before: caret)] == " " else { return (trimmed, nil) }
        let id = trimmed[trimmed.index(after: caret)...]
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return (trimmed, nil) }
        return (String(trimmed[..<caret]).trimmingCharacters(in: .whitespaces), String(id))
    }

    /// Removes one level of indentation written with spaces.
    private static func dedent(_ line: String) -> String {
        var result = Substring(line)
        var removed = 0
        while removed < 4, result.first == " " {
            result = result.dropFirst()
            removed += 1
        }
        return String(result)
    }

    // MARK: Writing

    static func serialize(_ board: Board) -> String {
        var out = "---\n" + board.frontMatter + "\n---\n\n"
        if !board.preamble.isEmpty { out += board.preamble + "\n\n" }

        // Each list is followed by two blank lines, as the Kanban plugin writes it.
        for lane in board.lanes {
            out += "## " + lane.title + "\n\n"
            if lane.marksComplete { out += "**Complete**\n" }
            for leading in lane.leadingLines { out += leading + "\n" }
            for card in lane.cards { out += line(for: card, marksComplete: lane.marksComplete) }
            for extra in lane.extraLines { out += extra + "\n" }
            out += "\n\n"
        }

        if !board.archive.isEmpty || !board.archiveLines.isEmpty {
            out += "***\n\n## Archive\n\n"
            // Above the cards, where an indented line cannot be taken for a card's notes.
            for extra in board.archiveLines { out += extra + "\n" }
            for card in board.archive { out += line(for: card, marksComplete: false) }
            out += "\n"
        }

        if let settings = board.settingsBlock {
            out += settings + "\n"
        }
        return out
    }

    private static func line(for card: BoardCard, marksComplete: Bool) -> String {
        let box = card.isDone || marksComplete ? "[x]" : "[ ]"
        var line = "- \(box) \(card.text) ^\(card.id)\n"
        if !card.body.isEmpty {
            for bodyLine in card.body.components(separatedBy: "\n") {
                line += bodyLine.isEmpty ? "\n" : "\t" + bodyLine + "\n"
            }
        }
        return line
    }

    /// Front matter with `key: value` set, written the way the Kanban plugin lays it out.
    static func frontMatter(_ yaml: String, setting key: String, to value: String) -> String {
        if FrontMatter.value(for: key, in: yaml) == value { return yaml }
        var lines = yaml.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
            lines[index] = "\(key): \(value)"
        } else {
            // Insert after the last non-empty line, keeping trailing blank lines.
            let insertAt = (lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? -1) + 1
            lines.insert("\(key): \(value)", at: insertAt)
        }
        return lines.joined(separator: "\n")
    }
}
