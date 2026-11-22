//
//  PageTasks.swift
//  LP
//
//  Which to-dos on a page count as tasks, and how to find one of them again. Home, the
//  calendar, reminders and widgets know a task by its place among the page's tasks; ticking it
//  off from there must change that same line, even if the page changed since it was read.
//

import Foundation

nonisolated enum PageTasks {

    struct Task: Equatable {
        /// Where the to-do is among the document's blocks.
        var block: Int
        var text: String
        var isDone: Bool
        var due: Day?
        var time: TimeOfDay?
    }

    /// The page's tasks in order: to-dos with some wording left once a due date is taken out.
    static func tasks(in document: MarkdownDocument) -> [Task] {
        var found: [Task] = []
        for (index, block) in document.blocks.enumerated() {
            guard case .todo(let status, _) = block.kind else { continue }
            let (text, due, time) = taskText(block.plainText)
            guard !text.isEmpty else { continue }
            found.append(Task(block: index, text: text, isDone: status != " ", due: due, time: time))
        }
        return found
    }

    /// The block of the task that was number `ordinal` on the page, with this wording, due date
    /// and time, and state. If the page changed since then, it is found by its wording and due
    /// date and time instead — only when exactly one task matches. A task that was already ticked
    /// off (or reopened) elsewhere, or that can't be told apart from another, is left alone: nil.
    static func block(ofTask ordinal: Int, text: String, due: Day?, time: TimeOfDay?, isDone: Bool,
                      in document: MarkdownDocument) -> Int? {
        let all = tasks(in: document)
        guard let index = locate(ordinal, among: all.map { ($0.text, $0.due, $0.time, $0.isDone) },
                                 text: text, due: due, time: time, isDone: isDone) else { return nil }
        return all[index].block
    }

    /// The rule for finding an item listed as number `ordinal` among `items` (wording, due date,
    /// time, done): at its place if it is still that item, and still in the state it was listed
    /// in; otherwise the one item that matches it. Shared by page tasks and board cards.
    static func locate(_ ordinal: Int, among items: [(text: String, due: Day?, time: TimeOfDay?, isDone: Bool)],
                       text: String, due: Day?, time: TimeOfDay?, isDone: Bool) -> Int? {
        func same(_ item: (text: String, due: Day?, time: TimeOfDay?, isDone: Bool)) -> Bool {
            item.text == text && item.due == due && item.time == time
        }
        if items.indices.contains(ordinal), same(items[ordinal]) {
            return items[ordinal].isDone == isDone ? ordinal : nil
        }
        let matches = items.indices.filter { same(items[$0]) }
        guard matches.count == 1, items[matches[0]].isDone == isDone else { return nil }
        return matches[0]
    }

    /// Separates a task's wording from a due date written as `📅 2026-11-20` or `due: 2026-11-20`,
    /// and from a time written right after the date (`📅 2026-11-20 14:00`).
    static func taskText(_ raw: String) -> (text: String, due: Day?, time: TimeOfDay?) {
        let line = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        for marker in ["📅", "due:", "due::", "@due"] {
            guard let range = line.range(of: marker, options: .caseInsensitive) else { continue }
            let tail = String(line[range.upperBound...])
            guard let day = Day.first(in: String(tail.prefix(16))) else { continue }
            var text = String(line[..<range.lowerBound])
            var time: TimeOfDay? = nil
            if let dateRange = tail.range(of: day.iso) {
                var rest = tail[dateRange.upperBound...]
                if let found = TimeOfDay.leading(in: rest) {
                    time = found.time
                    rest = found.rest
                }
                text += rest.trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            }
            return (text.trimmingCharacters(in: .whitespaces), day, time)
        }
        return (line.trimmingCharacters(in: .whitespaces), nil, nil)
    }
}
