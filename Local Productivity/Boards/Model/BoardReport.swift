//
//  BoardReport.swift
//  LP
//
//  A read-only summary of a board for people who don't have LP: how far along it is,
//  what is in each list, what is overdue and what changed recently. Written as Markdown
//  for the shared progress page (GitHub renders it), and as a self-contained HTML file
//  for exporting.
//

import Foundation

nonisolated enum BoardReport {

    struct Input {
        var title: String
        var icon: String?
        var board: Board
        var log: BoardActivityLog?
        var now: Date = Date()
        var today: Day = .today
    }

    // MARK: Markdown

    static func markdown(_ input: Input) -> String {
        let progress = BoardProgress(board: input.board, today: input.today)
        var out: [String] = []
        let heading = [input.icon, input.title].compactMap { $0 }.joined(separator: " ")
        out.append("# \(heading)")
        out.append("")
        out.append("**\(progress.percent)% complete** · \(progress.done) of \(progress.total) \(progress.total == 1 ? "card" : "cards") done  ")
        out.append("`\(bar(progress.fraction, width: 24))`")
        out.append("")

        var highlights: [String] = []
        if progress.overdue > 0 { highlights.append("⚠️ \(progress.overdue) overdue") }
        if progress.dueSoon > 0 { highlights.append("📅 \(progress.dueSoon) due in the next 3 days") }
        if let log = input.log {
            let recent = log.completedCount(withinDays: 7, now: input.now)
            if recent > 0 { highlights.append("✅ \(recent) completed this week") }
        }
        if !highlights.isEmpty {
            out.append(highlights.joined(separator: " · "))
            out.append("")
        }

        out.append("| List | Cards | |")
        out.append("|---|---:|---|")
        let largest = max(1, progress.perLane.map(\.count).max() ?? 1)
        for lane in progress.perLane {
            let label = lane.marksComplete ? "\(escapeTable(lane.title)) ✓" : escapeTable(lane.title)
            out.append("| \(label) | \(lane.count) | `\(bar(Double(lane.count) / Double(largest), width: 12))` |")
        }
        out.append("")

        for lane in input.board.lanes {
            out.append("## \(lane.title)\(lane.marksComplete ? " ✓" : "")")
            out.append("")
            if lane.cards.isEmpty {
                out.append("_Nothing here yet._")
            }
            for card in lane.cards {
                let done = card.isDone || lane.marksComplete
                var line = "- " + (done ? "✅ " : "") + escapeList(card.title.isEmpty ? "Untitled card" : card.title)
                if let due = card.due {
                    let overdue = !done && due < input.today
                    line += overdue ? " · **⚠️ overdue (\(due.shortTitle))**" : " · due \(due.shortTitle)"
                }
                if !card.tags.isEmpty {
                    line += " · " + card.tags.map { "`#\($0)`" }.joined(separator: " ")
                }
                if let checklist = card.checklist {
                    line += " · ☑︎ \(checklist.done)/\(checklist.total)"
                }
                out.append(line)
            }
            out.append("")
        }

        if let log = input.log, !log.events.isEmpty {
            out.append("## Recent activity")
            out.append("")
            for event in log.events.suffix(12).reversed() {
                out.append("- **\(event.at.formatted(.dateTime.day().month(.abbreviated).hour().minute()))** — \(escapeList(event.sentence))")
            }
            out.append("")
        }

        out.append("---")
        out.append("_Updated \(input.now.formatted(date: .abbreviated, time: .shortened)) · Shared from LP (Local Productivity)_")
        return out.joined(separator: "\n") + "\n"
    }

    /// A text progress bar such as `█████░░░░░`.
    static func bar(_ fraction: Double, width: Int) -> String {
        let clamped = min(max(fraction, 0), 1)
        let filled = Int((clamped * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    private static func escapeTable(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func escapeList(_ text: String) -> String {
        var result = text
        for character in ["*", "_", "`", "[", "]"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }

    // MARK: HTML

    // MARK: Document

    /// The same page as a plain document — headings, a table and lists, nothing that runs — for a
    /// service that turns HTML into its own kind of document (Google Drive makes a Google Doc of
    /// it). Card notes are never included.
    static func documentHTML(_ input: Input) -> String {
        let progress = BoardProgress(board: input.board, today: input.today)
        let heading = escapeHTML([input.icon, input.title].compactMap { $0 }.joined(separator: " "))
        var out = ["<!DOCTYPE html>", "<html><head><meta charset=\"utf-8\"><title>\(heading)</title></head><body>"]
        out.append("<h1>\(heading)</h1>")
        out.append("<p><b>\(progress.percent)% complete</b> · \(progress.done) of \(progress.total) \(progress.total == 1 ? "card" : "cards") done</p>")
        out.append("<p><code>\(bar(progress.fraction, width: 24))</code></p>")

        var highlights: [String] = []
        if progress.overdue > 0 { highlights.append("⚠️ \(progress.overdue) overdue") }
        if progress.dueSoon > 0 { highlights.append("📅 \(progress.dueSoon) due in the next 3 days") }
        if let log = input.log {
            let recent = log.completedCount(withinDays: 7, now: input.now)
            if recent > 0 { highlights.append("✅ \(recent) completed this week") }
        }
        if !highlights.isEmpty { out.append("<p>\(highlights.joined(separator: " · "))</p>") }

        out.append("<table><tr><th>List</th><th>Cards</th><th></th></tr>")
        let largest = max(1, progress.perLane.map(\.count).max() ?? 1)
        for lane in progress.perLane {
            out.append("<tr><td>\(escapeHTML(lane.title))\(lane.marksComplete ? " ✓" : "")</td><td>\(lane.count)</td>"
                       + "<td><code>\(bar(Double(lane.count) / Double(largest), width: 12))</code></td></tr>")
        }
        out.append("</table>")

        for lane in input.board.lanes {
            out.append("<h2>\(escapeHTML(lane.title))\(lane.marksComplete ? " ✓" : "")</h2>")
            guard !lane.cards.isEmpty else {
                out.append("<p><i>Nothing here yet.</i></p>")
                continue
            }
            out.append("<ul>")
            for card in lane.cards {
                let done = card.isDone || lane.marksComplete
                var line = (done ? "✅ " : "") + escapeHTML(card.title.isEmpty ? "Untitled card" : card.title)
                if let due = card.due {
                    let overdue = !done && due < input.today
                    line += overdue ? " · <b>⚠️ overdue (\(escapeHTML(due.shortTitle)))</b>" : " · due \(escapeHTML(due.shortTitle))"
                }
                if !card.tags.isEmpty {
                    line += " · " + card.tags.map { "#" + escapeHTML($0) }.joined(separator: " ")
                }
                if let checklist = card.checklist {
                    line += " · ☑︎ \(checklist.done)/\(checklist.total)"
                }
                out.append("<li>\(line)</li>")
            }
            out.append("</ul>")
        }

        if let log = input.log, !log.events.isEmpty {
            out.append("<h2>Recent activity</h2>")
            out.append("<ul>")
            for event in log.events.suffix(12).reversed() {
                out.append("<li><b>\(escapeHTML(event.at.formatted(.dateTime.day().month(.abbreviated).hour().minute())))</b> — \(escapeHTML(event.sentence))</li>")
            }
            out.append("</ul>")
        }

        out.append("<hr>")
        out.append("<p><i>Updated \(escapeHTML(input.now.formatted(date: .abbreviated, time: .shortened))) · Shared from LP (Local Productivity)</i></p>")
        out.append("</body></html>")
        return out.joined(separator: "\n") + "\n"
    }

    static func html(_ input: Input) -> String {
        let progress = BoardProgress(board: input.board, today: input.today)
        let palette = ["#3B82F6", "#8B5CF6", "#F59E0B", "#14B8A6", "#EC4899", "#64748B"]
        func laneColor(_ index: Int, _ complete: Bool) -> String { complete ? "#22A06B" : palette[index % palette.count] }

        var segments = ""
        var legend = ""
        for (index, lane) in progress.perLane.enumerated() where lane.count > 0 {
            let share = Double(lane.count) / Double(max(progress.total, 1)) * 100
            segments += "<span style=\"width:\(String(format: "%.2f", share))%;background:\(laneColor(index, lane.marksComplete))\" title=\"\(escapeHTML(lane.title)): \(lane.count)\"></span>"
            legend += "<li><i style=\"background:\(laneColor(index, lane.marksComplete))\"></i>\(escapeHTML(lane.title)) <b>\(lane.count)</b></li>"
        }

        var stats = "<div class=\"stat\"><b>\(progress.done)/\(progress.total)</b><span>cards done</span></div>"
        stats += "<div class=\"stat\(progress.overdue > 0 ? " warn" : "")\"><b>\(progress.overdue)</b><span>overdue</span></div>"
        stats += "<div class=\"stat\"><b>\(progress.dueSoon)</b><span>due in 3 days</span></div>"
        if let log = input.log {
            stats += "<div class=\"stat\"><b>\(log.completedCount(withinDays: 7, now: input.now))</b><span>done this week</span></div>"
        }

        var lanes = ""
        for (index, lane) in input.board.lanes.enumerated() {
            var cards = ""
            for card in lane.cards {
                let done = card.isDone || lane.marksComplete
                var meta = ""
                if let due = card.due {
                    let overdue = !done && due < input.today
                    meta += "<span class=\"chip\(overdue ? " overdue" : "")\">\(overdue ? "Overdue · " : "")\(escapeHTML(due.shortTitle))</span>"
                }
                for tag in card.tags { meta += "<span class=\"chip tag\">#\(escapeHTML(tag))</span>" }
                if let checklist = card.checklist { meta += "<span class=\"chip\">☑︎ \(checklist.done)/\(checklist.total)</span>" }
                cards += "<li class=\"card\(done ? " done" : "")\"><p>\(done ? "✓ " : "")\(escapeHTML(card.title.isEmpty ? "Untitled card" : card.title))</p>\(meta.isEmpty ? "" : "<div>\(meta)</div>")</li>"
            }
            if lane.cards.isEmpty { cards = "<li class=\"empty\">Nothing here yet</li>" }
            lanes += "<section class=\"lane\"><h3><i style=\"background:\(laneColor(index, lane.marksComplete))\"></i>\(escapeHTML(lane.title)) <span>\(lane.cards.count)</span></h3><ul>\(cards)</ul></section>"
        }

        var activity = ""
        if let log = input.log, !log.events.isEmpty {
            let items = log.events.suffix(15).reversed().map { event in
                "<li><time>\(escapeHTML(event.at.formatted(.dateTime.day().month(.abbreviated).hour().minute())))</time>\(escapeHTML(event.sentence))</li>"
            }.joined()
            activity = "<h2>Recent activity</h2><ul class=\"activity\">\(items)</ul>"
        }

        let trend = input.log.map { trendSVG($0.snapshots.suffix(30)) } ?? ""
        let heading = escapeHTML([input.icon, input.title].compactMap { $0 }.joined(separator: " "))

        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escapeHTML(input.title)) — Progress</title>
        <style>
        :root{--ink:#1d1d1f;--muted:#6e6e73;--line:rgba(0,0,0,.09);--card:#fff;--page:#f5f5f7;--accent:#2f6fde}
        @media (prefers-color-scheme:dark){:root{--ink:#f2f2f4;--muted:#a1a1a6;--line:rgba(255,255,255,.12);--card:#232326;--page:#161618;--accent:#5b8ef0}}
        *{box-sizing:border-box}body{margin:0;background:var(--page);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,sans-serif}
        main{max-width:1080px;margin:0 auto;padding:40px 20px 64px}h1{font-size:32px;margin:0 0 4px;letter-spacing:-.01em}
        .sub{color:var(--muted);margin:0 0 24px}.big{font-size:44px;font-weight:700;letter-spacing:-.02em}
        .bar{display:flex;height:12px;border-radius:6px;overflow:hidden;background:var(--line);margin:10px 0 12px}.bar span{display:block;height:100%}
        .legend{display:flex;flex-wrap:wrap;gap:14px;list-style:none;padding:0;margin:0 0 24px;color:var(--muted);font-size:13px}
        .legend i,h3 i{display:inline-block;width:9px;height:9px;border-radius:3px;margin-right:6px}.legend b{color:var(--ink);margin-left:2px}
        .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:28px}
        .stat{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px}.stat b{display:block;font-size:24px}.stat span{color:var(--muted);font-size:13px}
        .stat.warn b{color:#d93025}.lanes{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px}
        .lane{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px}.lane h3{margin:0 0 10px;font-size:14px}.lane h3 span{color:var(--muted);font-weight:500;margin-left:4px}
        .lane ul{list-style:none;padding:0;margin:0;display:grid;gap:8px}.card{border:1px solid var(--line);border-radius:10px;padding:10px 12px}.card p{margin:0}
        .card.done p{color:var(--muted)}.card div{margin-top:6px;display:flex;flex-wrap:wrap;gap:6px}.empty{color:var(--muted);font-size:13px;padding:4px 2px}
        .chip{font-size:12px;padding:1px 8px;border-radius:999px;background:var(--line)}.chip.overdue{background:rgba(217,48,37,.14);color:#d93025}.chip.tag{color:var(--accent)}
        h2{font-size:18px;margin:36px 0 12px}.activity{list-style:none;padding:0;margin:0}.activity li{padding:8px 0;border-top:1px solid var(--line)}.activity time{color:var(--muted);display:inline-block;min-width:130px}
        .trend{margin:0 0 28px}.trend svg{width:100%;height:auto}footer{color:var(--muted);font-size:12px;margin-top:40px}
        </style></head><body><main>
        <h1>\(heading)</h1>
        <p class="sub">Progress report · \(escapeHTML(input.now.formatted(date: .long, time: .shortened)))</p>
        <div class="big">\(progress.percent)%</div>
        <div class="bar">\(segments)</div>
        <ul class="legend">\(legend)</ul>
        <div class="stats">\(stats)</div>
        \(trend)
        <div class="lanes">\(lanes)</div>
        \(activity)
        <footer>Made with LP — Local Productivity</footer>
        </main></body></html>
        """
    }

    /// Total and completed cards over time as a small area chart, when there is enough history.
    private static func trendSVG(_ snapshots: ArraySlice<BoardSnapshot>) -> String {
        let points = Array(snapshots)
        guard points.count >= 2 else { return "" }
        let width = 1000.0
        let height = 160.0
        let maximum = Double(max(1, points.map(\.total).max() ?? 1))
        func x(_ index: Int) -> Double { Double(index) / Double(points.count - 1) * width }
        func y(_ value: Int) -> Double { height - Double(value) / maximum * (height - 12) - 6 }
        let totalLine = points.enumerated().map { "\(x($0.offset)),\(y($0.element.total))" }.joined(separator: " ")
        let doneLine = points.enumerated().map { "\(x($0.offset)),\(y($0.element.done))" }.joined(separator: " ")
        let doneArea = "0,\(height) " + doneLine + " \(width),\(height)"
        let first = points.first!.day.shortTitle
        let last = points.last!.day.shortTitle
        return """
        <div class="trend"><h2>Progress over time</h2>
        <svg viewBox="0 0 \(Int(width)) \(Int(height) + 24)" role="img" aria-label="Cards done and total from \(escapeHTML(first)) to \(escapeHTML(last))">
        <polygon points="\(doneArea)" fill="#22A06B" fill-opacity=".18"/>
        <polyline points="\(doneLine)" fill="none" stroke="#22A06B" stroke-width="3"/>
        <polyline points="\(totalLine)" fill="none" stroke="currentColor" stroke-opacity=".45" stroke-width="2" stroke-dasharray="6 6"/>
        <text x="0" y="\(Int(height) + 20)" font-size="13" fill="currentColor" opacity=".6">\(escapeHTML(first))</text>
        <text x="\(Int(width))" y="\(Int(height) + 20)" font-size="13" fill="currentColor" opacity=".6" text-anchor="end">\(escapeHTML(last)) · done (solid) vs total (dashed)</text>
        </svg></div>
        """
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
