//
//  Ownership tests — "person A makes something; person B tries to read it, change it and delete
//  it; every attempt must be refused".
//
//  LP has no server and no accounts of its own, so here the question is: can anything that isn't
//  you — someone else's copy of your folder, a folder someone hands you, a link on a web page, a
//  forged sign-in reply — make LP change something of yours? Every check here must say no (and
//  your own Mac must still be able to do what you asked).
//
//  Run with `Scripts/test.sh ownership`; with LP_TEST_VERBOSE=1 every check is printed.
//

import Foundation

var passed = 0
var failed = 0
let verbose = ProcessInfo.processInfo.environment["LP_TEST_VERBOSE"] != nil

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if condition {
        passed += 1
        if verbose { print("  ✓ \(message())") }
    } else {
        failed += 1
        print("✗ line \(line): \(message())")
    }
}

func section(_ title: String) {
    if verbose { print("\n\(title)") }
}

if verbose { print("") }

// MARK: - A shared progress page

section("A's shared progress page (a secret gist on A's GitHub account)")
do {
    let path = "Projects/Launch.md", board = "blaunch1"
    func page(_ id: String) -> BoardShare {
        BoardShare(gistID: id, url: URL(string: "https://gist.github.com/\(id)")!, fileName: "Launch — Progress.md", lastPublished: nil)
    }
    let aPage = page("aa5a315d61ae9438b18d")
    /// Whether a Mac with these permissions may update or delete `share`, as LP decides before it
    /// sends anything to GitHub.
    func may(_ share: BoardShare?, fileSays: String? = board, at place: String = path, on mac: Set<String>) -> Bool {
        ShareTrust.isTrusted(share, boardIDInFile: fileSays, historyBoardID: board, path: place, grants: mac)
    }
    // A shares the board on A's Mac: LP keeps a permission for that file, board and page.
    let macA: Set<String> = [ShareGrantKey.make(path: path, board: board, page: aPage.grantKey)]
    check(may(aPage, on: macA), "A's Mac may update and delete A's page")
    // B gets a copy of A's folder, or opens the same synced folder: the record comes along, the
    // permission doesn't.
    check(!may(aPage, on: []), "B's Mac can't update A's page, nor delete it (B's copy has the record, not the permission)")
    let macB: Set<String> = [ShareGrantKey.make(path: path, board: board, page: "bb5a315d61ae9438b18d")]
    check(!may(aPage, on: macB), "B's permission for B's own page doesn't reach A's page")
    // Someone hands A a folder whose history points at another of A's gists.
    check(!may(page("cc5a315d61ae9438b18d"), on: macA), "a history pointed at another of A's gists can't make A's Mac overwrite or delete that gist")
    check(!may(aPage, fileSays: "bother1", on: macA), "another board put into that file can't change the page")
    check(!may(aPage, fileSays: nil, on: macA), "a file without the board's ID can't change the page")
    check(!may(aPage, at: "Elsewhere/Launch.md", on: macA), "a copy in another place needs its own permission")
    let sneaky = page("../user/repos")
    check(!may(sneaky, on: [ShareGrantKey.make(path: path, board: board, page: sneaky.pageID)]),
          "an ID with a path in it never reaches GitHub, even with a permission")
    check(!may(nil, on: macA), "without a record there is nothing to change")
    // Reading: a shared page is published for whoever has its link — that is what sharing is (card
    // notes are never on it). Its address is made from the gist ID, never taken from the folder.
    check(aPage.pageURL?.absoluteString == "https://gist.github.com/aa5a315d61ae9438b18d", "the page's address is always on gist.github.com")
    var forged = aPage
    forged.url = URL(string: "file:///Applications/Calculator.app")!
    check(forged.pageURL?.absoluteString == "https://gist.github.com/aa5a315d61ae9438b18d", "a link written into the folder is never opened")
}

// MARK: - A page in someone's Google Drive

section("A's shared progress page in A's own Google Drive (a Google Doc)")
do {
    let path = "Projects/Launch.md", board = "blaunch1"
    let account = "google:a@example.com"
    let aPage = BoardShare(driveFileID: "1AbC-defGHIjkl_MNOpqr", account: account, fileName: "Launch — Progress", lastPublished: nil)
    func may(_ share: BoardShare?, on mac: Set<String>) -> Bool {
        ShareTrust.isTrusted(share, boardIDInFile: board, historyBoardID: board, path: path, grants: mac)
    }
    let macA: Set<String> = [ShareGrantKey.make(path: path, board: board, page: aPage.grantKey)]
    check(may(aPage, on: macA), "A's Mac may update and delete A's Drive page")
    check(!may(aPage, on: []), "B's copy of the folder can't update or delete it")
    var otherAccount = aPage
    otherAccount.account = "google:b@example.com"
    check(!may(otherAccount, on: macA), "a history pointed at another Google account can't use A's permission")
    var otherFile = aPage
    otherFile.pageID = "9ZzZ-defGHIjkl_MNOpqr"
    check(!may(otherFile, on: macA), "nor one pointed at another file in A's Drive")
    let gistGrant: Set<String> = [ShareGrantKey.make(path: path, board: board, page: aPage.pageID)]
    check(!may(aPage, on: gistGrant), "a permission for a gist with that ID doesn't count for a Drive page")
    var sneaky = aPage
    sneaky.pageID = "../../drive/v3/about"
    check(!may(sneaky, on: [ShareGrantKey.make(path: path, board: board, page: sneaky.grantKey)]),
          "a file ID with a path in it never reaches Google, even with a permission")
    check(aPage.pageURL?.host == "docs.google.com", "the page's address is always on docs.google.com, built from its ID")
}

// MARK: - Sign-in replies

section("A's sign-in to Google or Microsoft (the reply that brings A back to LP)")
do {
    let reply = URL(string: "com.googleusercontent.apps.1:/oauth2redirect?code=XYZ&state=abc")!
    check((try? OAuthRequests.code(from: reply, expectedState: "abc")) == "XYZ", "the reply to the sign-in A started is accepted")
    check((try? OAuthRequests.code(from: reply, expectedState: "other")) == nil,
          "a reply to any other sign-in is refused, so a forged one can't connect B's account to A's LP")
    let noState = URL(string: "com.googleusercontent.apps.1:/oauth2redirect?code=XYZ")!
    check((try? OAuthRequests.code(from: noState, expectedState: "abc")) == nil, "a reply without the sign-in's mark is refused")
    // PKCE: the code in a reply only works together with a secret LP made for that sign-in, which
    // never leaves the Mac.
    let mine = PKCE.makeVerifier(), theirs = PKCE.makeVerifier()
    check(mine != theirs && PKCE.challenge(for: mine) != PKCE.challenge(for: theirs), "each sign-in has its own secret; a stolen code is useless without it")
}

// MARK: - Links from outside

section("A link to LP from a web page or another app (localproductivity://)")
do {
    /// Every place a link can lead only shows something. A new kind of link that would change
    /// something stops this file compiling until it is checked here.
    func onlyShows(_ destination: LPLink.Destination) -> Bool {
        switch destination {
        case .home, .boards, .calendar, .page: return true
        }
    }
    let links = ["localproductivity://home", "localproductivity://boards", "localproductivity://calendar?day=2026-11-19",
                 "localproductivity://open?path=Notes/Plan.md"]
    check(links.allSatisfy { LPLink.destination(of: URL(string: $0)!).map(onlyShows) == true }, "a link can only show a page, the calendar, the boards or Home")
    for link in ["localproductivity://delete?path=Notes/Plan.md", "localproductivity://complete?task=Ship",
                 "localproductivity://share?board=Launch", "localproductivity://settings?token=x"] {
        check(LPLink.destination(of: URL(string: link)!) == nil, "a link can't delete, tick off, share or change settings: \(link) is ignored")
    }
    if case .page(let path)? = LPLink.destination(of: URL(string: "localproductivity://open?path=../../Library/Keychains/login.keychain-db")!) {
        check(PathSafety.contained(path) == nil, "a link can't reach outside the workspace folder")
    } else {
        check(false, "an open link is read as a page")
    }
    check(PathSafety.contained("/Users/b/Notes.md") == nil && PathSafety.contained("~/Notes.md") == nil, "nor name a file by its full path")
}

if verbose { print("") }
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
