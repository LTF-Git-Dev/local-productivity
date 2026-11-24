//
//  Safety tests.
//
//  Run with `Scripts/test.sh`. Content in a note can come from anyone, so these check that it
//  cannot reach outside the workspace or make LP run something.
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

// MARK: - Paths stay inside the workspace

check(PathSafety.contained("Projects/Launch") == "Projects/Launch", "an ordinary path is kept")
check(PathSafety.contained("") == "", "the root is fine")
check(PathSafety.contained("./Projects//Archive/") == "Projects/Archive", "empty and dot parts are dropped")
check(PathSafety.contained("../Secrets") == nil, "climbing out is refused")
check(PathSafety.contained("Projects/../../etc") == nil, "climbing out mid-path is refused")
check(PathSafety.contained("/etc/passwd") == nil, "absolute paths are refused")
check(PathSafety.contained("~/Library") == nil, "home-relative paths are refused")
check(PathSafety.contained("Notes..md") == "Notes..md", "two dots inside a name are fine")

let root = URL(fileURLWithPath: "/Users/someone/Vault")
check(PathSafety.isInside(root.appendingPathComponent("a/b.png"), root: root), "a file inside")
check(PathSafety.isInside(root, root: root), "the root itself")
check(!PathSafety.isInside(root.appendingPathComponent("../Other/x.png"), root: root), "a file outside via ..")
check(!PathSafety.isInside(URL(fileURLWithPath: "/Users/someone/Vault2/x.png"), root: root), "a sibling with a similar name")

// MARK: - Links

func action(_ text: String) -> LinkSafety.Action? { URL(string: text).map(LinkSafety.action(for:)) }
check(action("https://example.com") == .open, "web pages open")
check(action("HTTP://example.com") == .open, "scheme case does not matter")
check(action("mailto:someone@example.com") == .open, "e-mail opens")
check(action("file:///Users/someone/Vault/doc.pdf") == .file, "file links are checked as files")
check(action("zoommtg://zoom.us/join?confno=1") == .confirm, "other apps ask first")
check(action("x-apple.systempreferences:com.apple.preference.security") == .confirm, "system settings links ask first")
check(action("vnc://host") == .confirm, "screen sharing links ask first")

func canOpen(_ name: String) -> Bool { LinkSafety.canOpenFile(URL(fileURLWithPath: "/tmp/" + name)) }
for safe in ["photo.png", "photo.JPG", "doc.pdf", "notes.txt", "table.csv", "slides.key", "sheet.xlsx",
             "letter.docx", "song.mp3", "clip.mov", "archive.zip", "page.html", "data.json", "readme.md"] {
    check(canOpen(safe), "\(safe) opens")
}
for unsafe in ["Setup.command", "install.sh", "run.py", "tool.app", "Installer.pkg", "Image.dmg", "script.scpt",
               "go.terminal", "flow.workflow", "site.webloc", "file.fileloc", "profile.mobileconfig", "a.jar",
               "mystery.zzz", "noextension"] {
    check(!canOpen(unsafe), "\(unsafe) is only shown in Finder")
}

// MARK: - Board IDs

check(BoardIDSafety.isValid("bdemolaunch"), "a generated ID")
check(BoardIDSafety.isValid("b3k9-x_1"), "dashes and underscores")
check(!BoardIDSafety.isValid("../../Library/x"), "path characters are refused")
check(!BoardIDSafety.isValid(""), "empty is refused")
check(!BoardIDSafety.isValid(String(repeating: "a", count: 65)), "very long is refused")
check(!BoardIDSafety.isValid("café"), "only plain ASCII")

// MARK: - Writing through links

do {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent("lp-safety-\(UUID().uuidString)")
    let root = base.appendingPathComponent("vault")
    let outside = base.appendingPathComponent("elsewhere")
    try? manager.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
    try? manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try? manager.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: outside)
    defer { try? manager.removeItem(at: base) }

    check(PathSafety.resolvesInside(root.appendingPathComponent("Notes/New page.md"), root: root), "a new page in a folder of the workspace")
    check(PathSafety.resolvesInside(root.appendingPathComponent("New/Deeper/page.md"), root: root), "in folders that don't exist yet")
    check(PathSafety.resolvesInside(root, root: root), "the workspace itself")
    check(!PathSafety.resolvesInside(root.appendingPathComponent("Linked/page.md"), root: root),
          "a folder that is a link to somewhere else can't take a new page out of the workspace")
    check(!PathSafety.resolvesInside(root.appendingPathComponent("Linked/New/page.md"), root: root), "nor a folder made inside it")
    check(!PathSafety.resolvesInside(base.appendingPathComponent("page.md"), root: root), "outside altogether")
}

// MARK: - Sharing grant keys

do {
    let plain = ShareGrantKey.make(path: "Projects/Launch.md", board: "blaunch1", page: "aa5a315d61ae9438b18d")
    check(ShareGrantKey.parts(of: plain).map { [$0.path, $0.board, $0.page] } == ["Projects/Launch.md", "blaunch1", "aa5a315d61ae9438b18d"],
          "a grant key reads back as path, board and gist")
    let odd = ShareGrantKey.make(path: "A\u{1F}B.md", board: "bodd1", page: "bb5a315d61ae9438b18d")
    check(ShareGrantKey.parts(of: odd).map { [$0.path, $0.board, $0.page] } == ["A\u{1F}B.md", "bodd1", "bb5a315d61ae9438b18d"],
          "a path containing the separator is kept whole, and the board is still the board")
    check(ShareGrantKey.parts(of: "no separators") == nil, "a key without its parts is nothing")
}

// ClaudeSetup: the Terminal steps can't be broken by a folder's name.
check(ClaudeSetup.shellQuoted("plain") == "'plain'", "simple text is quoted")
check(ClaudeSetup.shellQuoted("it's; rm -rf ~") == "'it'\\''s; rm -rf ~'", "a quote inside can't end the quoting")
let helperPath = "/Applications/LP.app/Contents/Helpers/lp-mcp"
check(ClaudeSetup.allowHelper(helperPath) == "xattr -d com.apple.quarantine '/Applications/LP.app/Contents/Helpers/lp-mcp'", "step 1 clears the download flag")
let connectStep = ClaudeSetup.connect(helper: helperPath, workspace: "/Users/me/My Notes; echo hi")
check(connectStep == "claude mcp add --scope user lp -- '/Applications/LP.app/Contents/Helpers/lp-mcp' --workspace '/Users/me/My Notes; echo hi'",
      "step 2 connects this workspace as one quoted word: \(connectStep)")
check(ClaudeSetup.check == "claude mcp get lp" && ClaudeSetup.remove == "claude mcp remove lp --scope user", "steps 3 and replacing")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
