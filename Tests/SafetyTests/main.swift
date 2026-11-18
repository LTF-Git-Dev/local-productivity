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

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
