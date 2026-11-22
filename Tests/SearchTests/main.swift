//
//  Search tests.
//
//  Run with `Scripts/test.sh`. Covers which matches ⌘K lists under "In pages" (SearchHit.inPages):
//  every match not already listed under "Pages", including pages whose name holds only some of
//  the words.
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

func hit(_ path: String, titleMatch: Bool) -> SearchHit {
    SearchHit(path: path, title: (path as NSString).deletingPathExtension, icon: nil, snippet: "…", isTitleMatch: titleMatch)
}

// "launch budget": "Launch Plan.md" has "launch" in its name and "budget" only inside it, so it
// isn't under "Pages" (that needs every word in the name) — it must be under "In pages".
let launchPlan = hit("Projects/Launch Plan.md", titleMatch: true)
let budgetNotes = hit("Areas/Finances.md", titleMatch: false)
let launchBudget = hit("Projects/Launch Budget.md", titleMatch: true)

let listed = SearchHit.inPages([launchBudget, launchPlan, budgetNotes], listedAsPages: ["Projects/Launch Budget.md"])
check(listed.map(\.path) == ["Projects/Launch Plan.md", "Areas/Finances.md"],
      "a page matching partly by name stays; one already under Pages doesn't repeat: \(listed.map(\.path))")
check(listed.contains(launchPlan), "the mixed name-and-text match is kept (it was dropped before)")
check(!listed.contains(launchBudget), "a page listed under Pages isn't listed twice")

// Nothing listed under Pages: every match stays, in the index's order.
let all = SearchHit.inPages([budgetNotes, launchPlan], listedAsPages: [])
check(all.map(\.path) == ["Areas/Finances.md", "Projects/Launch Plan.md"], "order is kept: \(all.map(\.path))")

// A page whose name holds every word, beyond the seven names shown, still appears (here).
let beyondSeven = SearchHit.inPages([launchBudget], listedAsPages: ["Projects/Other.md"])
check(beyondSeven == [launchBudget], "a full name match not listed under Pages still shows")

check(SearchHit.inPages([], listedAsPages: ["Projects/Launch Plan.md"]).isEmpty, "no matches, nothing listed")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
