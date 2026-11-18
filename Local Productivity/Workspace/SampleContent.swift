//
//  SampleContent.swift
//  Local Productivity
//
//  A short guide that can be added to an empty workspace. It doubles as a tour of
//  what a page can contain.
//

import Foundation

enum SampleContent {

    /// Writes the starter guide into the workspace and returns its path.
    @discardableResult
    static func installStarterGuide(in workspace: Workspace) -> String? {
        try? workspace.createPage(in: "", title: "Getting Started", contents: starterGuide)
    }

    static let starterGuide = """
    ---
    icon: 👋
    ---

    Everything you write here is saved as plain Markdown in your folder. There is nothing to export and nothing to lock you in: the same files open in any other app, whenever you like.

    ## Write without the syntax

    Formatting appears as you type and the symbols get out of the way. Try a few:

    - Type `**bold**`, `*italic*` or `~~strike~~` and keep going
    - Start a line with `#`, `##` or `###` and a space for a heading
    - Start a line with `-` for a list, `1.` for a numbered list, or `[]` for a to-do
    - Press `/` on an empty line to see every kind of block

    > [!tip] Select any text to format it
    > A small bar appears above the selection. ⌘B, ⌘I and ⌘K work too.

    ## A few things to try

    - [x] Open this guide
    - [ ] Press ⌘N to make a page of your own
    - [ ] Press ⌘K to find anything
    - [ ] Open the Calendar and start today’s note

    ## Pages link to each other

    Type `[[` to link to another page. A link to a page that does not exist yet creates it when you click it.

    ---

    When you are done with this guide, move it to the Trash from the ••• menu.

    """
}
