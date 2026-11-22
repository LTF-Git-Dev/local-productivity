//
//  Task tests.
//
//  Run with `Scripts/test.sh`. Covers which to-dos count as tasks and finding a task again to
//  tick it off — the right box, even when the page changed since it was read.
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

func document(_ text: String) -> MarkdownDocument { MarkdownParser.parse(text) }

/// The block a task resolves to (its wording and date), or nil.
func resolved(_ ordinal: Int, _ text: String, due: String? = nil, at minutes: Int? = nil, done: Bool = false, in markdown: String) -> String? {
    let page = document(markdown)
    guard let index = PageTasks.block(ofTask: ordinal, text: text, due: due.flatMap(Day.init(iso:)),
                                      time: minutes.map(TimeOfDay.init(minutes:)), isDone: done, in: page) else { return nil }
    let task = PageTasks.taskText(page.blocks[index].plainText)
    return task.text + (task.due.map { " " + $0.iso } ?? "")
}

// MARK: - Wording and dates

check(PageTasks.taskText("Buy milk").text == "Buy milk", "plain wording")
check(PageTasks.taskText("Buy milk").due == nil, "no date")
check(PageTasks.taskText("Call Mina 📅 2026-11-20").text == "Call Mina", "the date is taken out")
check(PageTasks.taskText("Call Mina 📅 2026-11-20").due?.iso == "2026-11-20", "the date is read")
check(PageTasks.taskText("Call Mina due: 2026-11-20").due?.iso == "2026-11-20", "due: works too")
check(PageTasks.taskText("Call Mina 📅 2026-11-20 14:30").time?.minutes == 870, "a time after the date")
check(PageTasks.taskText("Call Mina 📅 2026-11-20 14:30").text == "Call Mina", "the time is taken out as well")
check(PageTasks.taskText("📅 2026-11-20").text.isEmpty, "a to-do that is only a date has no wording")

// MARK: - Which to-dos are tasks

do {
    let tasks = PageTasks.tasks(in: document("- [ ] 📅 2026-11-20\n- [ ] Buy milk\n- [x] Done already\n- [ ] \n\nA paragraph\n"))
    check(tasks.map(\.text) == ["Buy milk", "Done already"], "date-only and empty to-dos are not tasks: \(tasks.map(\.text))")
    check(tasks.map(\.isDone) == [false, true], "done state")
    check(tasks.first?.block == 1, "the block is the to-do's place among all blocks")
}

// MARK: - Finding a task again

check(resolved(0, "Buy milk", in: "- [ ] 📅 2026-11-20\n- [ ] Buy milk\n") == "Buy milk",
      "a date-only to-do above doesn't shift the count (the box that was ticked used to be the wrong one)")
check(resolved(1, "B", in: "- [ ] New\n- [ ] A\n- [ ] B\n") == "B", "a task added above since: found by its wording")
check(resolved(0, "A", in: "- [ ] B\n- [ ] A\n") == "A", "tasks reordered since: found by its wording")
check(resolved(0, "Buy milk", in: "- [x] Buy milk\n") == nil, "already ticked off elsewhere: nothing to change")
check(resolved(0, "Buy milk", done: true, in: "- [x] Buy milk\n") == "Buy milk", "reopening a done task")
check(resolved(0, "Buy milk", in: "- [ ] Something else\n") == nil, "a task that is gone: nothing to change")

do {
    let page = document("- [ ] Call\n- [ ] Call\n")
    check(PageTasks.block(ofTask: 1, text: "Call", due: nil, time: nil, isDone: false, in: page) == 1, "the same wording twice: the one at its place")
    check(PageTasks.block(ofTask: 0, text: "Call", due: nil, time: nil, isDone: false, in: page) == 0, "and the first one")
}

// The same wording with different dates: ticking the first off elsewhere, then ticking its old
// entry, must not tick the second.
check(resolved(0, "Call", due: "2026-11-20", in: "- [x] Call 📅 2026-11-20\n- [ ] Call 📅 2026-11-21\n") == nil,
      "a task already ticked off elsewhere is left alone, even if another has the same wording")
check(resolved(0, "Call", due: "2026-11-21", in: "- [ ] New\n- [ ] Call 📅 2026-11-20\n- [ ] Call 📅 2026-11-21\n") == "Call 2026-11-21",
      "a task that moved is found by its wording and its date")
check(resolved(0, "Call", in: "- [ ] New\n- [ ] Call\n- [ ] Call\n") == nil,
      "when the page changed and two tasks could be the one, neither is changed")
// The same wording and day at different times: the morning one ticked off elsewhere.
check(resolved(0, "Call", due: "2026-11-20", at: 540, in: "- [x] Call 📅 2026-11-20 09:00\n- [ ] Call 📅 2026-11-20 17:00\n") == nil,
      "a task's time tells it apart from another on the same day")
check(resolved(0, "Call", due: "2026-11-20", at: 1020, in: "- [ ] New\n- [ ] Call 📅 2026-11-20 09:00\n- [ ] Call 📅 2026-11-20 17:00\n") == "Call 2026-11-20",
      "and finds it when it moved")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
