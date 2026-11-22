//
//  Board tests.
//
//  Run with `Scripts/test.sh`. They check that boards read and write in the format
//  Obsidian's Kanban plugin uses, that LP keeps what it does not understand, and that
//  progress, activity and reports are worked out correctly.
//

import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("✗ line \(line): \(message())")
    }
}

/// A small seeded generator, so fuzz runs are repeatable.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(below bound: Int) -> Int {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

func visible(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: "⏎\n").replacingOccurrences(of: "\t", with: "→")
}

// A board as the Obsidian Kanban plugin writes it, with LP's card IDs.
let pluginBoard = """
---

kanban-plugin: basic

---

## To do

- [ ] Draft the brief #design @{2026-11-20} ^c1
- [ ] Book the venue 📅 2026-11-18 ^c2
\tCall two places first.
\t- [x] Shortlist
\t- [ ] Compare prices


## In progress

- [ ] Build [[Prototype|the prototype]] #eng #ui ^c3


## Done

**Complete**
- [x] Kick-off meeting ^c4


***

## Archive

- [x] Old idea ^c5

%% kanban:settings
```
{"kanban-plugin":"basic"}
```
%%

"""

// MARK: - Reading

let board = BoardParser.parse(pluginBoard)
check(BoardParser.isBoard(pluginBoard), "recognised as a board")
check(!BoardParser.isBoard("---\ntitle: x\n---\n# Note\n"), "an ordinary note is not a board")

// One rule on bytes, so a look at a file's start and a read of all of it always agree.
do {
    let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F467}"   // one character, 25 bytes
    let wide = "---\n# " + String(repeating: family, count: 60) + "\nkanban-plugin: basic\n---\n\n## Lane\n"
    check(wide.prefix(600).contains("kanban-plugin:") && wide.utf8.count > 1024, "the marker is in the first 600 characters but past 1 KB")
    check(!BoardParser.isBoard(wide), "past the first 1 KB it doesn't count, however few characters that is")
    let near = "---\n# " + String(repeating: "x", count: 990) + "\nkanban-plugin: basic\n---\n"
    check(BoardParser.isBoard(near), "within the first 1 KB it does, however many characters that is")
    for text in [wide, near, pluginBoard, "---\ntitle: x\n---\n", "\u{FEFF}---\nkanban-plugin: basic\n---\n"] {
        check(BoardParser.isBoard(head: Data(text.utf8.prefix(BoardParser.boardMarkerWindow))) == BoardParser.isBoard(text),
              "the start of a file tells as much as all of it")
    }
}
check(board.lanes.map(\.title) == ["To do", "In progress", "Done"], "lanes: \(board.lanes.map(\.title))")
check(board.lanes[2].marksComplete && !board.lanes[0].marksComplete, "the Done list marks cards complete")
check(board.lanes[0].cards.map(\.id) == ["c1", "c2"], "card IDs come from block IDs")
check(board.lanes[0].cards[1].body == "Call two places first.\n- [x] Shortlist\n- [ ] Compare prices", "indented notes: \(board.lanes[0].cards[1].body.debugDescription)")
check(board.lanes[0].cards[1].checklist?.done == 1 && board.lanes[0].cards[1].checklist?.total == 2, "checklist progress")
check(board.archive.map(\.id) == ["c5"], "archived cards")
check(board.settingsBlock?.contains("\"kanban-plugin\":\"basic\"") == true, "settings block kept")
check(board.lanes[2].cards.first?.isDone == true, "done card")

// MARK: - Card text

let brief = board.lanes[0].cards[0]
check(brief.title == "Draft the brief", "title without tags or date: \(brief.title)")
check(brief.tags == ["design"], "tags: \(brief.tags)")
check(brief.due == Day(iso: "2026-11-20"), "Kanban plugin date")
check(board.lanes[0].cards[1].due == Day(iso: "2026-11-18"), "Tasks plugin date")
check(board.lanes[1].cards[0].title == "Build the prototype", "wiki link reads as its text: \(board.lanes[1].cards[0].title)")
check(board.lanes[1].cards[0].tags == ["eng", "ui"], "several tags")
check(CardText.tags(in: "Learn C# and #123 issue #real") == ["real"], "C# and #123 are not tags")
check(BoardCard.text(title: "Ship it", tags: ["launch"], due: Day(iso: "2026-12-01"), previous: "Ship") == "Ship it #launch @{2026-12-01}",
      "composing card text")
check(BoardCard.text(title: "Pay rent", tags: [], due: Day(iso: "2026-12-01"), previous: "Pay 📅 2026-11-01") == "Pay rent 📅 2026-12-01",
      "the date style the card used is kept")

do {
    // Times: the Kanban plugin writes "@@{14:00}" after the date.
    let timed = "Call the printer @{2026-11-20} @@{14:00} #ops"
    check(CardText.due(in: timed) == Day(iso: "2026-11-20"), "the date of a card with a time")
    check(CardText.dueTime(in: timed)?.minutes == 840, "the time of a card")
    check(CardText.title(of: timed) == "Call the printer", "a time leaves no stray @ in the title: \(CardText.title(of: timed))")
    let timeFirst = "Call @@{9:30} @{2026-11-21}"
    check(CardText.due(in: timeFirst) == Day(iso: "2026-11-21"), "a time written before the date is not taken for it")
    check(CardText.dueTime(in: "Pay rent 📅 2026-11-30 2:30pm")?.minutes == 870, "a time after a 📅 date")
    check(CardText.title(of: "Pay rent 📅 2026-11-30 2:30pm") == "Pay rent", "and it leaves the title")
    check(CardText.dueTime(in: "Plan @{2026-11-20}") == nil, "no time when none is written")
}

do {
    // Editing a card keeps its time.
    let kanban = "Call the printer @{2026-11-20} @@{14:00} #ops"
    let renamed = CardText.settingTitle("Call the bindery", in: kanban)
    check(CardText.title(of: renamed) == "Call the bindery" && CardText.dueTime(in: renamed)?.minutes == 840
          && CardText.due(in: renamed) == Day(iso: "2026-11-20") && CardText.tags(in: renamed) == ["ops"],
          "renaming keeps the date, time and tags: \(renamed)")
    let tasks = "Pay rent 📅 2026-11-30 14:30"
    let renamedTask = CardText.settingTitle("Pay the rent", in: tasks)
    check(renamedTask == "Pay the rent 📅 2026-11-30 14:30", "renaming keeps a 📅 time: \(renamedTask)")
    let timeFirst = "Call @@{9:30} @{2026-11-21}"
    let moved = CardText.settingDue(Day(iso: "2026-11-25"), in: timeFirst)
    check(moved == "Call @@{9:30} @{2026-11-25}", "changing the date leaves a time written first alone: \(moved)")
    check(CardText.settingDue(nil, in: kanban) == "Call the printer #ops", "removing the date removes its time: \(CardText.settingDue(nil, in: kanban))")
    check(CardText.settingDue(nil, in: tasks) == "Pay rent", "removing a 📅 date removes its time: \(CardText.settingDue(nil, in: tasks))")
    check(CardText.settingDue(Day(iso: "2026-12-01"), in: tasks) == "Pay rent 📅 2026-12-01 14:30", "a new 📅 date keeps the time")
}

do {
    // Setting a card's time.
    let nine = TimeOfDay(hour: 9, minute: 5)
    let half = TimeOfDay(hour: 14, minute: 30)
    check(CardText.settingDueTime(half, in: "Call @{2026-11-20}") == "Call @{2026-11-20} @@{14:30}", "a time is added after the date")
    check(CardText.settingDueTime(nine, in: "Call @{2026-11-20} @@{14:00} #ops") == "Call @{2026-11-20} @@{09:05} #ops", "a time is changed where it is")
    check(CardText.settingDueTime(nil, in: "Call @{2026-11-20} @@{14:00} #ops") == "Call @{2026-11-20} #ops", "a time is removed")
    check(CardText.settingDueTime(half, in: "Pay 📅 2026-11-30") == "Pay 📅 2026-11-30 14:30", "a 📅 date gets its time after it")
    check(CardText.settingDueTime(nine, in: "Pay 📅 2026-11-30 14:30") == "Pay 📅 2026-11-30 09:05", "a 📅 time is changed")
    check(CardText.settingDueTime(nil, in: "Pay 📅 2026-11-30 14:30") == "Pay 📅 2026-11-30", "a 📅 time is removed")
    check(CardText.settingDueTime(half, in: "No date yet") == "No date yet", "no time without a date")
    check(CardText.dueTime(in: CardText.settingDueTime(half, in: "Call @{2026-11-20}"))?.minutes == 870, "and it reads back")
}

// MARK: - Editing card text

check(CardText.settingDue(Day(iso: "2026-12-01"), in: "Draft [[Brief]] #design @{2026-11-20}") == "Draft [[Brief]] #design @{2026-12-01}",
      "changing a date keeps the rest of the line")
check(CardText.settingDue(Day(iso: "2026-12-01"), in: "Pay rent 📅 2026-11-01 urgent") == "Pay rent 📅 2026-12-01 urgent",
      "an emoji date is changed in its own style")
check(CardText.settingDue(nil, in: "Pay rent 📅 2026-11-01 urgent") == "Pay rent urgent", "removing a date")
check(CardText.settingDue(Day(iso: "2026-12-01"), in: "Plain card") == "Plain card @{2026-12-01}", "adding a date")
check(CardText.settingDue(nil, in: "Plain card") == "Plain card", "removing a missing date changes nothing")
check(CardText.settingTags(["eng", "ux"], in: "Build [[Prototype|it]] #old @{2026-11-20}") == "Build [[Prototype|it]] #eng #ux @{2026-11-20}",
      "tags are replaced and sit before the date: \(CardText.settingTags(["eng", "ux"], in: "Build [[Prototype|it]] #old @{2026-11-20}"))")
check(CardText.settingTags([], in: "Learn C# #study") == "Learn C#", "removing tags leaves C# alone")
check(CardText.settingTitle("Ship it", in: "Old name #launch 📅 2026-12-01") == "Ship it #launch 📅 2026-12-01",
      "a new title keeps tags and date")

// MARK: - Writing

let written = BoardParser.serialize(board)
check(written == pluginBoard, "a plugin-style board writes back unchanged\n--- expected\n\(visible(pluginBoard))\n--- got\n\(visible(written))")
check(BoardParser.serialize(BoardParser.parse(written)) == written, "writing is stable")

let withoutIDs = BoardParser.parse("---\n\nkanban-plugin: basic\n\n---\n\n## Ideas\n\n- [ ] One\n- [ ] Two\n")
check(withoutIDs.lanes[0].cards.allSatisfy { !$0.hasStoredID && $0.id.hasPrefix("c") }, "cards without IDs get new ones")
let saved = BoardParser.serialize(withoutIDs)
check(saved.contains("- [ ] One ^c") && saved.contains("- [ ] Two ^c"), "new IDs are written: \(visible(saved))")
let reread = BoardParser.parse(saved)
check(reread.lanes[0].cards.map(\.id) == withoutIDs.lanes[0].cards.map(\.id), "written IDs read back the same")

let template = BoardParser.parse(BoardTemplate.markdown(boardID: "btest"))
check(template.boardID == "btest", "template board ID")
check(template.lanes.map(\.title) == ["To do", "In progress", "Done"] && template.lanes[2].marksComplete, "template lists")
check(BoardParser.serialize(template) == BoardTemplate.markdown(boardID: "btest"), "the template is already in written form\n\(visible(BoardParser.serialize(template)))")

check(BoardParser.frontMatter("\nkanban-plugin: basic\n", setting: "lp-board", to: "b1") == "\nkanban-plugin: basic\nlp-board: b1\n",
      "a key is added after the existing ones")
check(BoardParser.frontMatter("\nkanban-plugin: basic\nlp-board: old\n", setting: "lp-board", to: "b2") == "\nkanban-plugin: basic\nlp-board: b2\n",
      "an existing key is replaced")

// The key is found the way it is read, so what is written is what is read back.
do {
    let spaced = BoardParser.frontMatter("\nkanban-plugin: basic\nlp-board : bsource\n", setting: "lp-board", to: "b2")
    check(spaced == "\nkanban-plugin: basic\nlp-board: b2\n", "a key written with a space before its colon is replaced, not added again\n\(visible(spaced))")
    check(FrontMatter.value(for: "lp-board", in: spaced) == "b2", "and reads back as the new ID")
    let twice = BoardParser.frontMatter("\nlp-board: ba\nkanban-plugin: basic\nlp-board: bb\n", setting: "lp-board", to: "bc")
    check(twice == "\nkanban-plugin: basic\nlp-board: bc\n", "a key that appears twice is set once (after the marker)\n\(visible(twice))")
    let owned = BoardParser.frontMatter("\nlp-board:\n  - x\nkanban-plugin: basic\n", setting: "lp-board", to: "bd")
    check(owned == "\nkanban-plugin: basic\nlp-board: bd\n", "lines the old key owned go with it\n\(visible(owned))")
    check(BoardParser.frontMatter("\nkanban-plugin: basic\nlp-board : b2\n", setting: "lp-board", to: "b2") == "\nkanban-plugin: basic\nlp-board : b2\n",
          "nothing changes when it already reads as that ID")
    let file = BoardParser.settingFrontMatter("lp-board", to: "b9", in: "---\nkanban-plugin: basic\nlp-board : bsource\n---\n\n## Lane\n")
    check(file.map { BoardParser.parse($0).boardID } == "b9", "a board file reads back with the ID it was given")
}

// An ID before the plugin's marker moves to just after it, so a longer one can't push the
// marker out of the part of the file that makes it a board.
do {
    let wide = String(repeating: "\u{754C}", count: 330)   // 990 bytes
    let text = "---\nlp-board: a\n# \(wide)\nkanban-plugin: basic\n---\n\n## Lane\n"
    check(BoardParser.isBoard(text), "a board whose marker is just inside the first 1 KB")
    let set = BoardParser.settingFrontMatter("lp-board", to: "b4kq7zm2x", in: text)
    check(set.map(BoardParser.isBoard) == true, "is still a board with a longer ID\n\(visible(set ?? "nil"))")
    check(set.map { BoardParser.parse($0).boardID } == "b4kq7zm2x", "and reads back with it")
    check(set == "---\n# \(wide)\nkanban-plugin: basic\nlp-board: b4kq7zm2x\n---\n\n## Lane\n", "the ID now follows the marker")
    check(BoardParser.frontMatter("\nkanban-plugin: basic\nicon: x\nlp-board: a\n", setting: "lp-board", to: "bb") == "\nkanban-plugin: basic\nicon: x\nlp-board: bb\n",
          "an ID after the marker stays where it is")
}

// Recording a board's ID before LP moves it touches only the front matter.
do {
    let irregular = "---\n\nkanban-plugin: basic\n\n---\n\nIntro  with  odd   spacing\n## Lane\n- [ ] Card\n* [x] Other   ^c1\n\n%% kanban:settings\n{}\n%%"
    let set = BoardParser.settingFrontMatter("lp-board", to: "b9", in: irregular)
    check(set == irregular.replacingOccurrences(of: "kanban-plugin: basic\n", with: "kanban-plugin: basic\nlp-board: b9\n"),
          "only the ID line is added; the rest stays byte for byte\n\(visible(set ?? "nil"))")
    check(set.map { BoardParser.parse($0).boardID } == "b9", "and the board then has that ID")
    let crlf = irregular.replacingOccurrences(of: "\n", with: "\r\n")
    let setCRLF = BoardParser.settingFrontMatter("lp-board", to: "b9", in: crlf)
    check(setCRLF == crlf.replacingOccurrences(of: "kanban-plugin: basic\r\n", with: "kanban-plugin: basic\r\nlp-board: b9\r\n"),
          "Windows line endings are kept\n\(visible(setCRLF ?? "nil"))")
    let invalid = "---\nkanban-plugin: basic\nlp-board: ../x\n---\n\n## Lane\n"
    check(BoardParser.settingFrontMatter("lp-board", to: "b9", in: invalid) == "---\nkanban-plugin: basic\nlp-board: b9\n---\n\n## Lane\n",
          "an ID that can't be used is replaced")
    check(BoardParser.settingFrontMatter("lp-board", to: "b9", in: "---\nkanban-plugin: basic\nlp-board: b9\n---\n") == "---\nkanban-plugin: basic\nlp-board: b9\n---\n",
          "nothing changes when the ID is already there")
    check(BoardParser.settingFrontMatter("lp-board", to: "b9", in: "## Lane\n- [ ] Card\n") == nil, "no front matter: nothing to set")
    check(BoardParser.settingFrontMatter("lp-board", to: "b9", in: "---\nkanban-plugin: basic\n## Lane\n") == nil, "front matter that never closes: nothing to set")
}

do {
    let odd = "---\nkanban-plugin: basic\n---\n\nSome intro text.\n\n## Lane\n\nA stray paragraph\n- [ ] Card ^x1\n"
    let parsed = BoardParser.parse(odd)
    let out = BoardParser.serialize(parsed)
    check(out.contains("Some intro text.") && out.contains("A stray paragraph"), "unknown content is kept:\n\(visible(out))")
}

// MARK: - Progress

let today = Day(iso: "2026-11-19")!
let progress = BoardProgress(board: board, today: today)
check(progress.total == 4 && progress.done == 1, "totals exclude the archive: \(progress.total) \(progress.done)")
check(progress.overdue == 1, "the venue was due yesterday")
check(progress.dueSoon == 1, "the brief is due tomorrow")
check(progress.percent == 25, "percent")

// MARK: - What changed

do {
    var after = board
    // Move the brief to In progress, finish the venue by moving it to Done, rename the prototype card.
    let briefCard = after.lanes[0].cards.removeFirst()
    after.lanes[1].cards.append(briefCard)
    let venue = after.lanes[0].cards.removeFirst()
    after.lanes[2].cards.append(venue)
    after.lanes[1].cards[0].text = "Build the real prototype #eng"
    after.lanes[0].cards.append(BoardCard(id: "c9", text: "New card", body: "", isDone: false))
    let removed = after.lanes[2].cards.removeFirst()
    after.archive.append(removed)

    let events = BoardDiff.events(from: board, to: after)
    func has(_ kind: BoardEvent.Kind, _ card: String) -> Bool { events.contains { $0.kind == kind && $0.cardID == card } }
    check(has(.moved, "c1"), "moved between lists")
    check(has(.moved, "c2") && has(.completed, "c2"), "moving into a Complete list completes the card")
    check(has(.renamed, "c3"), "renamed")
    check(has(.created, "c9"), "created")
    check(has(.archived, "c4"), "archived")
    check(events.first { $0.kind == .moved && $0.cardID == "c1" }?.sentence == "Moved “Draft the brief” from To do to In progress",
          "readable activity")
}

// MARK: - Activity log

do {
    var log = BoardActivityLog(boardID: "b1")
    let start = Date(timeIntervalSince1970: 1_000_000)
    log.firstSeen["c1"] = start
    log.record([BoardEvent(at: start.addingTimeInterval(2 * 86_400), kind: .completed, cardID: "c1", cardTitle: "One")])
    check(log.averageDaysToDone().map { abs($0 - 2) < 0.001 } == true, "time to done")
    check(log.completedCount(withinDays: 7, now: start.addingTimeInterval(3 * 86_400)) == 1, "completed this week")
    log.snapshot(progress, on: today)
    log.snapshot(progress, on: today)
    check(log.snapshots.count == 1, "one snapshot per day")

    log.lastSeen = board
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let data = try? encoder.encode(log), let decoded = try? decoder.decode(BoardActivityLog.self, from: data) {
        check(decoded.lastSeen == board && decoded.events.count == log.events.count, "the log and the last-seen board are saved")
    } else {
        check(false, "the log encodes and decodes")
    }
    let older = #"{"boardID":"b0","events":[],"snapshots":[],"firstSeen":{}}"#
    check((try? decoder.decode(BoardActivityLog.self, from: Data(older.utf8)))?.lastSeen == nil, "logs saved before lastSeen existed still load")
}

do {
    // Logs are read leniently, so another version's additions never cost the history.
    var log = BoardActivityLog(boardID: "bx")
    log.record([BoardEvent(at: Date(timeIntervalSince1970: 1_800_000_000), kind: .completed, cardID: "c1", cardTitle: "Card")])
    log.lastSeen = BoardParser.parse(pluginBoard)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var json = try! JSONSerialization.jsonObject(with: encoder.encode(log)) as! [String: Any]
    check((try? decoder.decode(BoardActivityLog.self, from: encoder.encode(log))) == log, "a log reads back as written")
    json["lastSeen"] = ["unreadable": true]
    var events = json["events"] as! [[String: Any]]
    events.append(["id": UUID().uuidString, "cardID": "c2", "cardTitle": "Later", "kind": "someFutureKind", "at": "2027-01-01T00:00:00Z"])
    json["events"] = events
    let altered = try! JSONSerialization.data(withJSONObject: json)
    let read = try? decoder.decode(BoardActivityLog.self, from: altered)
    check(read?.events.count == 1 && read?.lastSeen == nil, "unreadable parts are skipped, the rest is kept")
    json.removeValue(forKey: "lastSeen")
    json.removeValue(forKey: "firstSeen")
    check((try? decoder.decode(BoardActivityLog.self, from: JSONSerialization.data(withJSONObject: json))) != nil, "an older log without newer fields reads")
}

// MARK: - Reports

do {
    let input = BoardReport.Input(title: "Launch", icon: "🚀", board: board, log: nil, now: Date(), today: today)
    let markdown = BoardReport.markdown(input)
    check(markdown.hasPrefix("# 🚀 Launch\n"), "report heading")
    check(markdown.contains("**25% complete**") && markdown.contains("1 of 4 cards done"), "report summary")
    check(markdown.contains("| To do | 2 |"), "lists table")
    check(markdown.contains("⚠️ overdue"), "overdue cards are flagged")
    check(BoardReport.bar(0.5, width: 10) == "█████░░░░░", "text bar")

    var risky = board
    risky.lanes[0].cards[0].text = "<script>alert(1)</script>"
    let html = BoardReport.html(BoardReport.Input(title: "A <b>board</b>", icon: nil, board: risky, log: nil, now: Date(), today: today))
    check(!html.contains("<script>alert") && html.contains("&lt;script&gt;"), "card text is escaped in HTML")
    check(html.contains("<title>A &lt;b&gt;board&lt;/b&gt; — Progress</title>"), "title is escaped")
}

// MARK: - Templates

check(BoardTemplate.simple.markdown(boardID: "btest") == "---\n\nkanban-plugin: basic\nlp-board: btest\n\n---\n\n## To do\n\n\n\n## In progress\n\n\n\n## Done\n\n**Complete**\n\n\n%% kanban:settings\n```\n{\"kanban-plugin\":\"basic\"}\n```\n%%\n",
      "the simple template is exactly what earlier versions wrote")
for template in BoardTemplate.allCases {
    let text = template.markdown(boardID: "b\(template.rawValue)")
    let parsed = BoardParser.parse(text)
    check(BoardParser.isBoard(text), "\(template.title) is recognised as a board")
    check(parsed.lanes.map(\.title) == template.lists, "\(template.title) has its lists: \(parsed.lanes.map(\.title))")
    check(parsed.lanes.last?.marksComplete == true && parsed.lanes.dropLast().allSatisfy { !$0.marksComplete },
          "\(template.title): only the last list counts as done")
    check(parsed.boardID == "b\(template.rawValue)", "\(template.title) carries its board ID")
    check(BoardParser.serialize(parsed) == text, "\(template.title) writes back unchanged")
}

// MARK: - Edge cases in hand-edited files

let head = "---\n\nkanban-plugin: basic\n\n---\n\n"
do {
    // A card copied in Obsidian keeps the original's block ID.
    let copied = BoardParser.parse(head + "## To do\n\n- [ ] Call Mina ^c1\n- [ ] Call Mina ^c1\n\n\n")
    let cards = copied.lanes[0].cards
    check(cards.count == 2 && cards[0].id == "c1" && cards[1].id != "c1", "a copied card gets its own ID: \(cards.map(\.id))")
    check(cards[0].hasStoredID && !cards[1].hasStoredID, "only the copy's ID is new")
    var reread = BoardParser.parse(BoardParser.serialize(copied))
    reread.adoptIDs(from: copied)
    check(Set(reread.lanes[0].cards.map(\.id)).count == 2, "the two stay separate after saving")
    var again = copied
    again.adoptIDs(from: copied)
    check(again.lanes[0].cards[1].id != "c1", "a copy is never matched to the original's ID")
}
do {
    // "---" inside a card's notes is part of the notes, not the archive rule.
    let source = head + "## To do\n\n- [ ] Plan ^c1\n\tFirst part\n\t---\n\tSecond part\n- [ ] Next ^c2\n\n\n"
    let parsed = BoardParser.parse(source)
    check(parsed.lanes.count == 1 && parsed.lanes[0].cards.count == 2, "a rule in a card's notes keeps the list together")
    check(parsed.lanes[0].cards.first?.body == "First part\n---\nSecond part", "the rule stays in the notes")
    check(BoardParser.serialize(parsed) == source, "and the board writes back unchanged")
}
do {
    // A note under a list's title stays above its cards; notes under the archive are kept.
    let source = head + "## To do\n\nCards for the spring launch\n- [ ] Plan ^c1\n\n\n***\n\n## Archive\n\nOld cards\n- [x] Kick-off ^c0\n\n"
    let parsed = BoardParser.parse(source)
    check(parsed.lanes[0].leadingLines == ["Cards for the spring launch"], "a list's note is kept above its cards")
    check(parsed.archiveLines == ["Old cards"], "a note in the archive is kept")
    check(BoardParser.serialize(parsed) == source, "a board with notes writes back unchanged: \(visible(BoardParser.serialize(parsed)))")
}

// MARK: - Fuzzing: random boards

do {
    let pieces = ["---\n\nkanban-plugin: basic\n\n---\n\n", "## To do\n\n", "## Done\n\n**Complete**\n", "- [ ] Card ", "- [x] Done ",
                  "#tag ", "@{2026-11-20} ", "📅 2026-11-21 ", "^c1 ", "^c2", "\n", "\tnote line\n", "  spaced note\n", "***\n\n## Archive\n\n",
                  "%% kanban:settings\n```\n{}\n```\n%%\n", "stray text\n", "[[Link|alias]] ", "<b>", "^", "^^", "- [", "- [?] odd\n",
                  "\t---\n", "---\n"]
    /// Words the writer may merge or drop: a second "**Complete**" or "## Archive" adds nothing.
    let structural: Set<String> = ["Complete", "Archive"]
    func words(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) where !structural.contains(String(word)) {
            counts[String(word), default: 0] += 1
        }
        return counts
    }
    var random = SeededRandom(seed: 99)
    var unstable: [String] = []
    var lost: [String] = []
    for _ in 0..<3000 {
        var text = ""
        for _ in 0..<(1 + random.next(below: 25)) { text += pieces[random.next(below: pieces.count)] }
        let board = BoardParser.parse(text)
        let written = BoardParser.serialize(board)
        var reread = BoardParser.parse(written)
        // Cards without stored IDs get fresh ones on each read; compare after matching them up.
        reread.adoptIDs(from: board)
        if BoardParser.serialize(reread) != written, unstable.count < 2 { unstable.append(text) }
        let after = words(written)
        if words(text).contains(where: { after[$0.key, default: 0] < $0.value }), lost.count < 2 { lost.append(text) }
        _ = BoardProgress(board: board)
        _ = BoardReport.markdown(BoardReport.Input(title: "t", icon: nil, board: board, log: nil))
    }
    check(unstable.isEmpty, "random boards write stably; first cases: \(unstable.map(visible))")
    check(lost.isEmpty, "random boards lose no text when written; first cases: \(lost.map(visible))")
}

// MARK: - Layout and dragging

do {
    // Three lists in a 1,400pt board: room for wide lists, capped at the maximum.
    check(BoardLayout.laneWidth(available: 1400, lanes: 3) == BoardLayout.maximumLane, "wide windows cap list width")
    // Three lists in 1,150pt: the space is shared out and everything fits without scrolling.
    let shared = BoardLayout.laneWidth(available: 1150, lanes: 3)
    check(shared > BoardLayout.minimumLane && shared < BoardLayout.maximumLane, "lists share a medium window: \(shared)")
    check(BoardLayout.margin * 2 + BoardLayout.addListWidth + (shared + BoardLayout.spacing) * 3 <= 1150, "shared lists fit without scrolling")
    // Four lists don't fit in 1,100pt, so they keep the minimum and the board scrolls.
    check(BoardLayout.laneWidth(available: 1100, lanes: 4) == BoardLayout.minimumLane, "too many lists for the window scroll")
    // Narrow windows keep the minimum and scroll.
    check(BoardLayout.laneWidth(available: 700, lanes: 4) == BoardLayout.minimumLane, "narrow windows keep the minimum width")
    check(BoardLayout.laneWidth(available: 900, lanes: 0) == BoardLayout.maximumLane, "an empty board is fine")

}

// MARK: - Where a dragged card lands

do {
    func lane(_ id: String, x: CGFloat, cards: [String]) -> BoardDropTarget.Lane {
        BoardDropTarget.Lane(id: id, frame: CGRect(x: x, y: 0, width: 260, height: 600),
                             cards: cards.enumerated().map { ($1, CGRect(x: x + 10, y: 50 + CGFloat($0) * 70, width: 240, height: 60)) })
    }
    let lanes = [lane("todo", x: 0, cards: ["a", "b", "c"]), lane("doing", x: 280, cards: ["d"]), lane("done", x: 560, cards: [])]
    func target(_ x: CGFloat, _ y: CGFloat, dragging: String = "z") -> BoardDropTarget? {
        BoardDropTarget.find(at: CGPoint(x: x, y: y), in: lanes, dragging: dragging)
    }
    check(target(100, 60) == BoardDropTarget(laneID: "todo", beforeCardID: "a"), "above the first card's middle → before it")
    check(target(100, 110) == BoardDropTarget(laneID: "todo", beforeCardID: "b"), "below a's middle → before b")
    check(target(100, 500) == BoardDropTarget(laneID: "todo", beforeCardID: nil), "below every card → the end")
    check(target(400, 60) == BoardDropTarget(laneID: "doing", beforeCardID: "d"), "another list")
    check(target(700, 300) == BoardDropTarget(laneID: "done", beforeCardID: nil), "an empty list")
    check(target(270, 60)?.laneID == "todo", "the gap between lists goes to the nearest list")
    check(target(2000, 60)?.laneID == "done", "past the last list → the last list")
    check(target(100, 110, dragging: "b") == BoardDropTarget(laneID: "todo", beforeCardID: "c"), "the dragged card is ignored")
    check(BoardDropTarget.find(at: .zero, in: [], dragging: "a") == nil, "no lists, no target")
}

// MARK: - Reading again keeps list IDs

do {
    let first = BoardParser.parse(pluginBoard)
    var again = BoardParser.parse(pluginBoard)
    check(again.lanes.map(\.id) != first.lanes.map(\.id), "every read makes new list IDs")
    again.adoptIDs(from: first)
    check(again.lanes.map(\.id) == first.lanes.map(\.id), "lists still there keep theirs, so actions aimed at them still work")
    var renamed = BoardParser.parse(pluginBoard.replacingOccurrences(of: "## In progress", with: "## Doing"))
    renamed.adoptIDs(from: first)
    check(renamed.lanes[0].id == first.lanes[0].id && renamed.lanes[2].id == first.lanes[2].id && renamed.lanes[1].id != first.lanes[1].id,
          "a list renamed elsewhere is a new list; the others keep their IDs")
    // Two lists with the same title: when one is removed elsewhere, the other must not take its ID
    // (a pending action aimed at the removed one would then act on it).
    let twins = BoardParser.parse(head + "## To do\n\n- [ ] A\n\n\n## To do\n\n- [ ] B\n\n\n")
    var survivor = BoardParser.parse(head + "## To do\n\n- [ ] B\n\n\n")
    survivor.adoptIDs(from: twins)
    check(!twins.lanes.map(\.id).contains(survivor.lanes[0].id), "lists that shared a title don't hand their IDs on")
}

// MARK: - Card edits

do {
    let card = board.lanes[0].cards[0]
    var edit = CardEdit()
    check(edit.isEmpty, "an edit that changes nothing")
    edit.title = "Write the brief"
    let retitled = edit.applied(to: card)
    check(retitled.title == "Write the brief" && retitled.tags == ["design"] && retitled.due == card.due,
          "only the title changes: \(retitled.text)")
    var newer = card
    newer.body = "Notes written in another app"
    check(edit.applied(to: newer).body == "Notes written in another app", "notes changed elsewhere survive a title edit")
    var undated = CardEdit()
    undated.changesDue = true
    check(undated.applied(to: card).due == nil, "removing the date")
    var notes = CardEdit()
    notes.body = "New notes"
    notes.isDone = true
    let done = notes.applied(to: card)
    check(done.body == "New notes" && done.isDone && done.text == card.text, "notes and state change; the text doesn't")
}

// MARK: - Shared page links

do {
    func share(_ id: String, _ url: String) -> BoardShare {
        BoardShare(gistID: id, url: URL(string: url)!, fileName: "Board — Progress.md", lastPublished: nil)
    }
    check(share("aa5a315d61ae9438b18d", "https://gist.github.com/aa5a315d61ae9438b18d").pageURL?.absoluteString
          == "https://gist.github.com/aa5a315d61ae9438b18d", "a real gist's page")
    // The link written in the history file is never used: it could name anything.
    check(share("aa5a315d61ae9438b18d", "file:///Users/someone/payload.command").pageURL?.absoluteString
          == "https://gist.github.com/aa5a315d61ae9438b18d", "a forged link in the history is ignored")
    check(share("../../user/repos", "https://gist.github.com/x").pageURL == nil, "an ID with a path in it is not a gist ID")
    check(share("", "https://gist.github.com/").pageURL == nil, "nor is an empty one")
    check(!BoardShare.isValidGistID("abc def") && !BoardShare.isValidGistID("zoommtg:") && BoardShare.isValidGistID("1234567"),
          "gist IDs are letters and digits")
}

// MARK: - Sharing through Google Drive

do {
    func body(_ request: URLRequest?) -> String { String(data: request?.httpBody ?? Data(), encoding: .utf8) ?? "" }
    let id = "1AbC-defGHIjkl_MNOpqr"
    check(GoogleDriveMapping.isValidFileID(id) && !GoogleDriveMapping.isValidFileID("../../drive/v3/about")
          && !GoogleDriveMapping.isValidFileID("short") && !GoogleDriveMapping.isValidFileID("1AbC defGHIjkl"), "Drive file IDs are letters, digits, - and _")
    check(GoogleDriveMapping.pageURL(fileID: id)?.absoluteString == "https://docs.google.com/document/d/1AbC-defGHIjkl_MNOpqr/view",
          "the page's address is made from its ID")
    check(GoogleDriveMapping.pageURL(fileID: "evil.example/x") == nil, "and nothing else becomes one")

    let create = GoogleDriveMapping.createRequest(name: "Launch — Progress", html: "<h1>Launch</h1>", boundary: "B1")
    check(create.httpMethod == "POST" && create.url?.absoluteString == "https://www.googleapis.com/upload/drive/v3/files?fields=id&uploadType=multipart",
          "a page is created by uploading it: \(create.url?.absoluteString ?? "")")
    check(create.value(forHTTPHeaderField: "Content-Type") == "multipart/related; boundary=B1", "as two parts")
    check(body(create) == "--B1\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{\"mimeType\":\"application\\/vnd.google-apps.document\",\"name\":\"Launch — Progress\"}\r\n--B1\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<h1>Launch</h1>\r\n--B1--\r\n",
          "its name, made into a Google Doc, and the page: \(body(create))")
    let update = GoogleDriveMapping.updateRequest(fileID: id, name: "Launch", html: "<p>new</p>", boundary: "B2")
    check(update?.httpMethod == "PATCH" && update?.url?.absoluteString == "https://www.googleapis.com/upload/drive/v3/files/\(id)?fields=id&uploadType=multipart",
          "an update replaces the same file, so the link stays")
    check(body(update).contains("{\"name\":\"Launch\"}") && !body(update).contains("mimeType"), "keeping it a Google Doc")
    let publish = GoogleDriveMapping.publishRequest(fileID: id)
    check(publish?.httpMethod == "POST" && publish?.url?.absoluteString == "https://www.googleapis.com/drive/v3/files/\(id)/permissions?fields=id",
          "the page is made viewable")
    check(body(publish) == #"{"allowFileDiscovery":false,"role":"reader","type":"anyone"}"#, "by anyone with the link, read only, not searchable")
    let delete = GoogleDriveMapping.deleteRequest(fileID: id)
    check(delete?.httpMethod == "DELETE" && delete?.url?.absoluteString == "https://www.googleapis.com/drive/v3/files/\(id)", "and deleted")
    check(GoogleDriveMapping.updateRequest(fileID: "../x", name: "a", html: "", boundary: "B") == nil && GoogleDriveMapping.publishRequest(fileID: "a/b") == nil
          && GoogleDriveMapping.deleteRequest(fileID: "") == nil, "a file ID that isn't one is never sent")
    check((try? GoogleDriveMapping.fileID(from: Data(#"{"id":"\#(id)"}"#.utf8))) == id, "the new file's ID is read")
    check((try? GoogleDriveMapping.fileID(from: Data(#"{"id":"../../x"}"#.utf8))) == nil, "only if it is one")

    // The page itself: the same content as on GitHub, as a plain document.
    let text = """
    ---
    kanban-plugin: basic
    ---

    ## To do <b>now</b>

    - [ ] Fix <script>alert(1)</script> & co @{2026-11-25} #a<b>
    \tPrivate note: the budget is 10k


    ## Done

    **Complete**
    - [x] Shipped


    """
    let page = BoardReport.documentHTML(BoardReport.Input(title: "Launch <x>", icon: nil, board: BoardParser.parse(text), log: nil,
                                                          now: Date(timeIntervalSince1970: 1_800_000_000), today: Day(year: 2026, month: 11, day: 20)))
    check(page.contains("<h1>Launch &lt;x&gt;</h1>") && page.contains("<h2>To do &lt;b&gt;now&lt;/b&gt;</h2>"), "titles are text, not markup")
    check(page.contains("Fix &lt;script&gt;alert(1)&lt;/script&gt; &amp; co") && !page.contains("<script"), "a card can't add markup to the page")
    check(!page.contains("Private note") && !page.contains("budget"), "card notes are never shared")
    check(page.contains("<li>✅ Shipped</li>") && page.contains("<table>"), "lists, cards and the summary table are there")
}

// MARK: - Shared pages: GitHub and Google Drive in one record

do {
    func decode(_ text: String) -> BoardShare? { try? JSONDecoder().decode(BoardShare.self, from: Data(text.utf8)) }
    func keys(_ share: BoardShare) -> Set<String> {
        let data = (try? JSONEncoder().encode(share)) ?? Data()
        return Set(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]).keys)
    }
    // A record from before Drive.
    let old = decode(#"{"gistID":"aa5a315d61ae9438b18d","url":"https://gist.github.com/aa5a315d61ae9438b18d","fileName":"Launch — Progress.md","updatesAutomatically":true}"#)
    check(old?.service == .gist && old?.pageID == "aa5a315d61ae9438b18d" && old?.account == nil, "a record from before Drive is a gist")
    check(old.map(keys) == ["gistID", "url", "fileName", "updatesAutomatically"], "and is saved exactly as before, for older versions")
    // A Drive page.
    let drive = BoardShare(driveFileID: "1AbC-defGHIjkl_MNOpqr", account: "google:a@example.com", fileName: "Launch — Progress", lastPublished: nil)
    let data = (try? JSONEncoder().encode(drive)) ?? Data()
    let back = try? JSONDecoder().decode(BoardShare.self, from: data)
    check(back == drive && keys(drive).isSuperset(of: ["service", "gistID", "account"]), "a Drive page keeps its service and account")
    check(drive.pageURL?.absoluteString == "https://docs.google.com/document/d/1AbC-defGHIjkl_MNOpqr/view"
          && old?.pageURL?.absoluteString == "https://gist.github.com/aa5a315d61ae9438b18d", "each page's address is built from its ID")
    check(decode(#"{"service":"oneDrive","gistID":"x1234567890","url":"https://x","fileName":"x"}"#) == nil,
          "a service LP doesn't know isn't taken for a gist")
    let unknown = try? JSONDecoder().decode(BoardActivityLog.self, from: Data(#"{"boardID":"b1","share":{"service":"oneDrive","gistID":"x1234567890","url":"https://x","fileName":"x"}}"#.utf8))
    check(unknown?.boardID == "b1" && unknown?.share == nil, "and the rest of the history still reads")
    // What counts as a real page.
    var noAccount = drive
    noAccount.account = nil
    var oddAccount = drive
    oddAccount.account = "google:a@example.com/../b"
    var gistWithAccount = old!
    gistWithAccount.account = "google:a@example.com"
    check(drive.isWellFormed && !noAccount.isWellFormed && !oddAccount.isWellFormed && !gistWithAccount.isWellFormed,
          "a Drive page needs its account; a gist has none")
    check(noAccount.pageURL == nil, "and only a real page gets an address")
    // Permissions are kept apart by service and account.
    check(old?.grantKey == "aa5a315d61ae9438b18d", "a gist's permission is its ID, as before")
    check(drive.grantKey == "gdrive:google:a@example.com/1AbC-defGHIjkl_MNOpqr", "a Drive page's names its account and file")

    // The list of Drive pages LP made.
    var registry = DrivePageRegistry()
    registry.add("1AbC-defGHIjkl_MNOpqr", account: "google:a@example.com")
    registry.add("1AbC-defGHIjkl_MNOpqr", account: "google:a@example.com")
    registry.add("2XyZ-defGHIjkl_MNOpqr", account: "google:a@example.com")
    registry.add("../not-an-id", account: "google:a@example.com")
    registry.add("3QqQ-defGHIjkl_MNOpqr", account: "google:b@example.com")
    check(registry.pages(of: "google:a@example.com") == ["1AbC-defGHIjkl_MNOpqr", "2XyZ-defGHIjkl_MNOpqr"], "pages are listed once, by account")
    registry.remove("1AbC-defGHIjkl_MNOpqr", account: "google:a@example.com")
    registry.remove("2XyZ-defGHIjkl_MNOpqr", account: "google:a@example.com")
    check(registry.pages(of: "google:a@example.com").isEmpty && registry.pages(of: "google:b@example.com").count == 1 && registry.pages.count == 1,
          "and leave the list when deleted")

    // Drive work on its way, and disconnecting (which waits for it and lets nothing new start).
    var work = DriveWork()
    let a = "google:a@example.com", b = "google:b@example.com"
    check(work.begin(a) && work.begin(a) && work.isRunning(a) && !work.isRunning(b), "work is counted per account")
    work.end(a)
    check(work.isRunning(a), "one piece of work ending leaves the other running")
    work.startDisconnecting(a)
    check(!work.begin(a) && work.isRunning(a), "while an account is being disconnected, nothing new starts — what runs keeps running")
    check(work.begin(b), "another account isn't held up")
    work.end(a)
    work.end(b)
    check(!work.isRunning(a) && !work.isRunning(b) && work.running.isEmpty, "until it ends; then disconnecting can go on")
    work.end(a)
    check(work.running.isEmpty, "ending what isn't running changes nothing")
    work.endDisconnecting(a)
    check(!work.isDisconnecting(a) && work.begin(a), "once disconnecting is over (or called off), work starts again")
}

// MARK: - Where a token's access is managed

check(GitHubTokenPages.accessPage(forToken: "ghp_x").absoluteString == "https://github.com/settings/tokens"
      && GitHubTokenPages.accessPage(forToken: "github_pat_x").absoluteString == "https://github.com/settings/personal-access-tokens",
      "a token's page on GitHub, by its kind")

// MARK: - Moving cards

do {
    var moving = board
    moving.moveCards(["c1"], toLane: "a list that no longer exists", before: nil)
    check(moving == board, "moving to a list that is gone changes nothing (the cards used to vanish)")
    let done = board.lanes[2].id
    moving.moveCards(["c2", "c1"], toLane: done, before: nil)
    check(moving.lanes[0].cards.isEmpty && moving.lanes[2].cards.map(\.id) == ["c4", "c2", "c1"],
          "moved to the end, in the order asked: \(moving.lanes[2].cards.map(\.id))")
    check(moving.lanes[2].cards.allSatisfy(\.isDone), "moving into a Complete list marks cards done")
    moving.moveCards(["c1"], toLane: board.lanes[1].id, before: "c3")
    check(moving.lanes[1].cards.map(\.id) == ["c1", "c3"], "moved before a given card")
    check(moving.lanes[1].cards[0].isDone == false, "moving out of a Complete list marks it not done")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
