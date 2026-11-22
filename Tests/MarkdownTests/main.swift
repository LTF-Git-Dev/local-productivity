//
//  Markdown engine tests.
//
//  These run without Xcode: `Scripts/test.sh` compiles the Markdown sources together
//  with this file and executes the result. They guard the one thing the app must
//  never get wrong — reading a note and writing it back without damaging it.
//

import Foundation

// MARK: - Tiny test harness

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

/// The file must come back byte for byte.
func exact(_ source: String, line: UInt = #line) {
    let output = MarkdownSerializer.serialize(MarkdownParser.parse(source))
    check(output == source, "not preserved\n--- expected\n\(visible(source))\n--- got\n\(visible(output))", line: line)
}

/// A description of a document that ignores how it happened to be formatted in the source.
func shape(_ document: MarkdownDocument) -> [String] {
    document.blocks.map { block in
        var kind = "\(block.kind)"
        if case .table(var table) = block.kind {
            table.source = nil
            kind = "\(BlockKind.table(table))"
        }
        if case .bullet = block.kind { kind = "bullet" }
        if case .todo(let status, _) = block.kind { kind = "todo(\(status))" }
        if case .numbered = block.kind { kind = "numbered" }
        if case .divider = block.kind { kind = "divider" }
        if case .heading(let level, _) = block.kind { kind = "heading(\(level))" }
        if case .code(let info, _) = block.kind { kind = "code(\(info))" }
        let normalized = InlineParser.merged(block.runs.map { run -> InlineRun in
            var style = run.style
            if style.bold != nil { style.bold = .asterisk }
            if style.italic != nil { style.italic = .asterisk }
            style.escaped = false
            return InlineRun(text: run.text, style: style)
        })
        let runs = normalized.map { "\($0.text)|\($0.style == .plain ? "" : "\($0.style)")" }
        return "\(block.indent) \(kind) \(runs)"
    }
}

/// Writing the document and reading it back must give the same structure, and writing again the same text.
func stable(_ source: String, line: UInt = #line) {
    let first = MarkdownParser.parse(source)
    let written = MarkdownSerializer.serialize(first)
    let second = MarkdownParser.parse(written)
    let rewritten = MarkdownSerializer.serialize(second)
    check(written == rewritten, "not idempotent\n--- first\n\(visible(written))\n--- second\n\(visible(rewritten))", line: line)
    let before = shape(first)
    let after = shape(second)
    check(before == after, "structure changed\n--- before\n\(before.joined(separator: "\n"))\n--- after\n\(after.joined(separator: "\n"))\n--- text\n\(visible(written))", line: line)
}

func runs(_ source: String) -> [InlineRun] { InlineParser.parse(source) }

func describe(_ runs: [InlineRun]) -> String {
    runs.map { run -> String in
        var tags: [String] = []
        if run.style.bold != nil { tags.append("b") }
        if run.style.italic != nil { tags.append("i") }
        if run.style.strikethrough { tags.append("s") }
        if run.style.highlight { tags.append("h") }
        if run.style.code { tags.append("code") }
        if run.style.raw { tags.append("raw") }
        if run.style.escaped { tags.append("esc") }
        if let link = run.style.link { tags.append("link:\(link.destination)") }
        if let wiki = run.style.wikiLink { tags.append("wiki:\(wiki.target)") }
        return tags.isEmpty ? run.text : "\(run.text){\(tags.joined(separator: ","))}"
    }.joined(separator: "·")
}

func inline(_ source: String, _ expected: String, line: UInt = #line) {
    let description = describe(runs(source))
    check(description == expected, "inline \(source.debugDescription)\n    expected \(expected)\n    got      \(description)", line: line)
    let written = InlineSerializer.serialize(runs(source))
    check(InlineSerializer.isEquivalent(runs(written), runs(source)),
          "inline round trip \(source.debugDescription) → \(written.debugDescription)", line: line)
    check(written == source, "inline source changed \(source.debugDescription) → \(written.debugDescription)", line: line)
}

/// Runs built in the editor must survive being written and read back.
func survives(_ built: [InlineRun], line: UInt = #line) {
    let written = InlineSerializer.serialize(built)
    let expected = describe(InlineParser.merged(built))
    let actual = describe(runs(written))
    check(InlineSerializer.isEquivalent(runs(written), built),
          "styled text changed: \(written.debugDescription)\n    expected \(expected)\n    got      \(actual)", line: line)
}

/// Whatever happens to the styling, the words themselves must never change.
func keepsText(_ built: [InlineRun], line: UInt = #line) {
    let written = InlineSerializer.serialize(built)
    let before = built.map(\.text).joined()
    let after = runs(written).map(\.text).joined().replacingOccurrences(of: "*", with: "")
    check(after == before.replacingOccurrences(of: "*", with: ""), "text changed: \(before.debugDescription) → \(written.debugDescription)", line: line)
}

func kinds(_ source: String) -> [String] {
    MarkdownParser.parse(source).blocks.map { block in
        switch block.kind {
        case .paragraph: return block.isEmptyParagraph ? "empty" : "p"
        case .heading(let level, _): return "h\(level)"
        case .bullet: return "bullet\(block.indent)"
        case .numbered: return "number\(block.indent)"
        case .todo(let status, _): return "todo\(block.indent)[\(status)]"
        case .quote: return "quote"
        case .callout(let type, _, _): return "callout(\(type))"
        case .code: return block.indent > 0 ? "code\(block.indent)" : "code"
        case .divider: return "divider"
        case .image: return "image"
        case .table: return "table"
        case .raw: return "raw"
        }
    }
}

func blocks(_ source: String, _ expected: [String], line: UInt = #line) {
    let actual = kinds(source)
    check(actual == expected, "blocks of \(source.debugDescription)\n    expected \(expected)\n    got      \(actual)", line: line)
    stable(source, line: line)
}

// MARK: - Inline parsing

inline("plain text", "plain text")
inline("some **bold** text", "some ·bold{b}· text")
inline("some *italic* and _italic_", "some ·italic{i}· and ·italic{i}")
inline("***both***", "both{b,i}")
inline("**bold *nested* bold**", "bold {b}·nested{b,i}· bold{b}")
inline("~~gone~~ and ==marked==", "gone{s}· and ·marked{h}")
inline("`code` and ``co`de``", "code{code}· and ·co`de{code}")
inline("a * b * c", "a * b * c")
inline("snake_case_name", "snake_case_name")
inline("2*3*4", "2·3{i}·4")
inline("a == b and c == d", "a == b and c == d")
inline("escaped \\*star\\*", "escaped ·*{esc}·star·*{esc}")
inline("[link](https://example.com)", "link{link:https://example.com}")
inline("[**bold** link](page.md \"Title\")", "bold{b,link:page.md}· link{link:page.md}")
inline("see https://example.com/a_b, ok", "see ·https://example.com/a_b{link:https://example.com/a_b}·, ok")
inline("<https://example.com>", "https://example.com{link:https://example.com}")
inline("[[Page]] and [[Folder/Page|alias]]", "Page{wiki:Page}· and ·alias{wiki:Folder/Page}")
inline("footnote[^1] here", "footnote·[^1]{raw}· here")
inline("math $a_b * c_d$ done", "math ·$a_b * c_d${raw}· done")
inline("costs $5 and $10", "costs $5 and $10")
inline("html <br> and <span class=\"x\">y</span>", "html ·<br>{raw}· and ·<span class=\"x\">{raw}·y·</span>{raw}")
inline("%%hidden%% shown", "%%hidden%%{raw}· shown")
inline("image ![alt](pic.png) inline", "image ·![alt](pic.png){raw}· inline")
inline("embed ![[Other Note]] inline", "embed ·![[Other Note]]{raw}· inline")
inline("unclosed **bold", "unclosed **bold")
inline("unclosed [link", "unclosed [link")
inline("a [b] c", "a [b] c")
inline("**bold**text", "bold{b}·text")
inline("line one\nline two", "line one\nline two")
inline("*a **b** c*", "a {i}·b{b,i}· c{i}")
inline("**a** *b*", "a{b}· ·b{i}")
inline("**a***b*", "a{b}·b{i}")
inline("`` `tick` ``", "`tick`{code}")
inline("#tag and #nested/tag", "#tag and #nested/tag")

// MARK: - Text styled in the editor

survives([.plain("hello "), InlineRun(text: "world ", style: InlineStyle(bold: .asterisk)), .plain("again")])
survives([InlineRun(text: " padded ", style: InlineStyle(italic: .asterisk))])
survives([.plain("a"), InlineRun(text: "b", style: InlineStyle(bold: .asterisk)), InlineRun(text: "c", style: InlineStyle(italic: .asterisk)), .plain("d")])
survives([InlineRun(text: "ab ", style: InlineStyle(bold: .asterisk)), InlineRun(text: "cd", style: InlineStyle(bold: .asterisk, italic: .asterisk)), InlineRun(text: " ef", style: InlineStyle(italic: .asterisk))])
keepsText([InlineRun(text: "ab", style: InlineStyle(bold: .asterisk)), InlineRun(text: "cd", style: InlineStyle(bold: .asterisk, italic: .asterisk)), InlineRun(text: "ef", style: InlineStyle(italic: .asterisk))])
survives([.plain("literal *stars* and _unders_ and `ticks`")])
survives([.plain("brackets [like](this) and [[these]]")])
survives([.plain("tildes ~~x~~ equals ==y== ok")])
survives([.plain("back\\slash and \\* done")])
survives([.plain("5 * 3 = 15, a_b, x == y")])
survives([InlineRun(text: "code with ` tick", style: InlineStyle(code: true))])
survives([InlineRun(text: "x", style: InlineStyle(strikethrough: true, highlight: true)), .plain(" tail")])
survives([InlineRun(text: "link text", style: InlineStyle(link: LinkInfo(destination: "https://a.b/c (d)")))])
survives([InlineRun(text: "bold", style: InlineStyle(bold: .asterisk, link: LinkInfo(destination: "x.md"))), InlineRun(text: " plain", style: InlineStyle(link: LinkInfo(destination: "x.md")))])
survives([InlineRun(text: "Target", style: InlineStyle(wikiLink: WikiLinkInfo(target: "Target", hasAlias: false))), .plain(" then "), InlineRun(text: "shown", style: InlineStyle(wikiLink: WikiLinkInfo(target: "Real", hasAlias: true)))])
survives([InlineRun(text: "snake_case", style: InlineStyle(italic: .underscore))])
survives([.plain("un"), InlineRun(text: "frigging", style: InlineStyle(italic: .underscore)), .plain("believable")])

// MARK: - Block structure

blocks("# Title\n\nParagraph one.\n\nParagraph two.\n", ["h1", "p", "p"])
blocks("Title\n=====\n\nSub\n---\n", ["h1", "h2"])
blocks("- a\n- b\n  - c\n    - d\n- e\n", ["bullet0", "bullet0", "bullet1", "bullet2", "bullet0"])
blocks("- a\n\t- b\n\t\t- c\n\t- d\n", ["bullet0", "bullet1", "bullet2", "bullet1"])
blocks("1. one\n2. two\n   - nested\n3. three\n", ["number0", "number0", "bullet1", "number0"])
blocks("- [ ] open\n- [x] done\n  - [ ] child\n", ["todo0[ ]", "todo0[x]", "todo1[ ]"])
blocks("- [1] a citation, not a task\n", ["bullet0"])
blocks("> quote line one\n> line two\n\n> another quote\n", ["quote", "quote"])
blocks("> [!note] Heads up\n> Body text\n", ["callout(note)"])
blocks("> [!warning]\n> Careful\n", ["callout(warning)"])
blocks("```swift\nlet x = 1\n\nprint(x)\n```\n", ["code"])
blocks("~~~\nfenced with tildes\n~~~\n", ["code"])
blocks("    indented code\n    more\n", ["code"])
blocks("text\n\n---\n\nmore\n", ["p", "divider", "p"])
blocks("***\n", ["divider"])
blocks("![alt](image.png)\n\n![[photo.jpg|300]]\n", ["image", "image"])
blocks("| a | b |\n| --- | :-: |\n| 1 | 2 |\n", ["table"])
blocks("<div class=\"x\">\nhello\n</div>\n\nafter\n", ["raw", "p"])
blocks("$$\nx = y^2\n$$\n\nafter\n", ["raw", "p"])
blocks("%%\nprivate\n%%\n\nafter\n", ["raw", "p"])
blocks("a\n\n\nb\n", ["p", "empty", "p"])
blocks("a\n\n\n\n\nb\n", ["p", "empty", "empty", "empty", "p"])
blocks("- item\n\n  continued paragraph\n- next\n", ["bullet0", "p", "bullet0"])
blocks("- item\n\n  ```\n  code in list\n  ```\n", ["bullet0", "code1"])
blocks("para\n- interrupts\n", ["p", "bullet0"])
blocks("para\n2. does not interrupt\n", ["p"])
blocks("# Heading\ntext right under\n", ["h1", "p"])
blocks("text\n# Heading\n", ["p", "h1"])
blocks("1. a\n\n\n2. b\n", ["number0", "empty", "number0"])
blocks("#hashtag is not a heading\n", ["p"])
blocks("[^1]: A footnote definition\n", ["p"])
blocks("* star bullet\n+ plus bullet\n", ["bullet0", "bullet0"])
blocks("- a\n\n- b\n", ["bullet0", "bullet0"])
blocks("---\ntitle: Hello\ntags: [a, b]\n---\n\n# Body\n", ["h1"])
blocks("---\n\nNot front matter\n\n---\n", ["divider", "p", "divider"])

// MARK: - Byte-for-byte preservation

exact("# Title\n\nSome **bold**, *italic*, _under_, ~~strike~~, ==mark==, `code`.\n")
exact("---\ntitle: Note\nicon: 🚀\n---\n\n# Heading\n\nBody.\n")
exact("---\ntitle: Note\n---\n# Heading directly after\n")
exact("- one\n- two\n    - four spaces\n    - again\n- three\n")
exact("- one\n\t- tab child\n\t\t- tab grandchild\n- two\n")
exact("* star\n* list\n\n+ plus\n")
exact("1. first\n2. second\n3. third\n")
exact("5. starts at five\n6. six\n")
exact("1) paren\n2) style\n")
exact("- [ ] todo\n- [x] done\n- [-] cancelled\n- [/] half\n")
exact("> quoted\n> text\n>\n> more\n")
exact("> [!tip]+ Title here\n> - a list inside\n> - a callout\n")
exact("```python title=\"x.py\"\ndef f():\n    return 1\n```\n")
exact("````\n```\nnested fence\n```\n````\n")
exact("Text with a [link](https://example.com \"T\") and [[Wiki|alias]] and [[Plain]].\n")
exact("Line one\nline two\nline three\n")
exact("Trailing spaces  \nhard break\n")
exact("| Name  | Qty |\n|:------|----:|\n| Apple |   3 |\n")
exact("Para\n\n\n\nGap of three blank lines\n")
exact("![[image.png]]\n\n![alt text](path/to/img.jpg)\n")
exact("Some text\n\n- - -\n\n___\n")
exact("Setext\n======\n\nSecond\n------\n")
exact("Escapes: \\* \\_ \\# \\[ \\] kept.\n")
exact("Inline <span style=\"color:red\">html</span> and $e=mc^2$ and footnote[^note].\n\n[^note]: The note.\n")
exact("- item\n\n  second paragraph of item\n\n- next item\n")
exact("1. step\n\n   ```sh\n   run\n   ```\n\n2. next\n")
exact("Windows\r\nline endings\r\n\r\n- kept\r\n")
exact("# Heading\ntext\n## Another\n- list\n\ntext\n")
exact("Visit https://example.com/path?q=1 or <mailto:a@b.co>.\n")
exact("Term with_underscore and 2 * 3 and a == b.\n")
exact("\n\nLeading blank lines\n")
exact("An unclosed **bold and a stray _underscore and a [bracket.\n")
exact("Year\n2024. A sentence that begins with a number.\n")
exact("- [1] Smith et al., a citation\n- [2] Another one\n")
exact("Maths: a*b, 2 ~ 3, x ~~ y, a=b, and c == d.\n")
exact("- # not a heading inside a list\n- > nor a quote\n")
exact("Dash - in the middle\nand - on the next line - too\n")

// MARK: - Normalisation never loses content

stable("* a\n  * b\n\n    para in b\n\n  * c\n")
exact("1. a\n1. b\n1. c\n")
exact("1) x\n1) y\n\n- bullet\n\n3. starts at three\n4. four\n")
stable("> lazy\ncontinuation\n")
stable("text\n===\nmore\n---\n")
stable("- a\n-\n- c\n")
stable("Header | Other\n--- | ---\nx | y\n")
stable("<!-- comment -->\n\ntext\n")
stable("    code\n\n    more code\n\ntext\n")
stable("- a\n\n\n\n- b\n")
stable("```\nunterminated fence\n")
stable("text  \n\n  indented text\n")
stable("- [ ] task\n  continuation of task\n")
stable("#\n\n##\n")
stable("- \n")
stable(">\n")
stable("\\# not a heading\n\n\\- not a list\n\n1\\. not numbered\n")

// MARK: - Documents built in the editor

func built(_ blocks: [Block], line: UInt = #line) {
    let document = MarkdownDocument(blocks: blocks)
    let written = MarkdownSerializer.serialize(document)
    let before = shape(document)
    let after = shape(MarkdownParser.parse(written))
    check(before == after, "built document changed\n--- before\n\(before.joined(separator: "\n"))\n--- after\n\(after.joined(separator: "\n"))\n--- text\n\(visible(written))", line: line)
}

built([.paragraph("First"), .paragraph("Second")])
built([Block(kind: .heading1, runs: [.plain("Title")]), .paragraph("Body")])
built([.paragraph("Intro"), Block(kind: .rule), .paragraph("Outro")])
built([.paragraph("Before"), Block(kind: .numbered(number: 3, delimiter: "."), runs: [.plain("three")])])
built([.paragraph("- looks like a list")])
built([.paragraph("# looks like a heading")])
built([.paragraph("> looks like a quote")])
built([.paragraph("1. looks numbered")])
built([.paragraph("---")])
built([.paragraph("line\n- second line looks like a list\n=== and an underline")])
built([Block(kind: .bulletItem, runs: [.plain("[ ] not a task")])])
built([Block(kind: .bulletItem, runs: [.plain("parent")]),
       Block(kind: .bulletItem, indent: 1, runs: [.plain("child")]),
       Block(kind: .paragraph, indent: 1, runs: [.plain("note under parent")]),
       Block(kind: .bulletItem, runs: [.plain("sibling")])])
built([Block(kind: .numberedItem, runs: [.plain("one")]),
       Block(kind: .numberedItem, runs: [.plain("two")]),
       Block(kind: .codeBlock, indent: 1, runs: [.plain("code\n\nwith blank")]),
       Block(kind: .numberedItem, runs: [.plain("three")])])
built([Block(kind: .quote, runs: [.plain("one\ntwo")]), Block(kind: .quote, runs: [.plain("separate")])])
built([Block(kind: .note, runs: [.plain("Body only")]), .paragraph("after")])
built([Block(kind: .callout(type: "tip", fold: "", hasTitle: true), runs: [.plain("Title\nBody")])])
built([Block(kind: .codeBlock, runs: [.plain("```\ninner fence\n```")])])
built([Block(kind: .openTodo, runs: [.plain("task")]), Block(kind: .todo(status: "x", marker: "-"), runs: [.plain("done")])])
built([Block(kind: .heading2, runs: [.plain("Ends with #")]), Block(kind: .heading3, runs: [.plain("C#")])])
built([.paragraph("a"), .paragraph(""), .paragraph(""), .paragraph("b")])
built([Block(kind: .image(ImageInfo(source: "my image.png", alt: "An image"))), .paragraph("caption")])
built([Block(kind: .table(TableInfo(alignments: [.left, .right], header: ["A", "B"], rows: [["1", "2"], ["3", ""]]))), .paragraph("after")])
built([Block(kind: .rule), .paragraph("after a leading rule"), Block(kind: .rule)])
built([Block(kind: .bulletItem, indent: 3, runs: [.plain("too deep is clamped")])].map { var b = $0; b.indent = 0; return b })

// MARK: - Numbering after edits

func numbering(_ source: String, insertAt index: Int, _ expected: String, line: UInt = #line) {
    var document = MarkdownParser.parse(source)
    document.blocks.insert(Block(kind: .numberedItem, runs: [.plain("new")]), at: index)
    let output = MarkdownSerializer.serialize(document)
    check(output == expected, "numbering\n--- expected\n\(visible(expected))\n--- got\n\(visible(output))", line: line)
}

numbering("1. a\n2. b\n", insertAt: 2, "1. a\n2. b\n3. new\n")
numbering("1. a\n2. b\n", insertAt: 1, "1. a\n2. new\n3. b\n")
numbering("1. a\n1. b\n", insertAt: 2, "1. a\n1. b\n1. new\n")
numbering("5. a\n6. b\n", insertAt: 2, "5. a\n6. b\n7. new\n")
do {
    var document = MarkdownParser.parse("1. a\n2. b\n3. c\n")
    document.blocks.remove(at: 1)
    let output = MarkdownSerializer.serialize(document)
    check(output == "1. a\n2. c\n", "removing an item renumbers the rest: \(visible(output))")
}

// MARK: - Saving with the paragraph cache

do {
    let sources = [
        "# Title\n\nPlain words here.\n\n- one\n- two **bold**\n  - nested *it*\n\n1. first\n2. second\n\n> quote\n\n- [ ] task 📅 2026-11-20\n",
        "Intro\n\n1. Introduction at the start of a paragraph\n\nText with a literal *star and _underscore\n\n- [x] done\n",
        "Line one\nline two continues\n\n# Heading\n\nA [[wiki]] link and `code` and ==mark==.\n"
    ]
    let cache = SerializerCache()
    for source in sources {
        let document = MarkdownParser.parse(source)
        let expected = MarkdownSerializer.serialize(document)
        check(MarkdownSerializer.serialize(document, cache: cache) == expected, "a first save with the cache matches")
        check(MarkdownSerializer.serialize(document, cache: cache) == expected, "a repeat save from the cache matches")
    }
    // Editing one paragraph between saves.
    var document = MarkdownParser.parse(sources[0])
    _ = MarkdownSerializer.serialize(document, cache: cache)
    document.blocks[1].runs = [.plain("Changed words here.")]
    check(MarkdownSerializer.serialize(document, cache: cache) == MarkdownSerializer.serialize(document), "an edited paragraph is written fresh")
    // A paragraph that needs escaping is never served from a cached plain version.
    var risky = MarkdownParser.parse("Safe text\n")
    _ = MarkdownSerializer.serialize(risky, cache: cache)
    risky.blocks[0].runs = [.plain("1. Looks like a list")]
    check(MarkdownSerializer.serialize(risky, cache: cache) == "1\\. Looks like a list\n", "escaping still applies with the cache: \(visible(MarkdownSerializer.serialize(risky, cache: cache)))")
}

// MARK: - Fuzzing: random documents built from Markdown fragments

do {
    // Garbage in: anything may be tidied (a closing fence added, ``` code written with one backtick,
    // a stray list number corrected), but nothing may be lost and writing must settle at once.
    let fragments = ["# ", "## ", "###### ", "- ", "* ", "+ ", "1. ", "2) ", "10. ", "- [ ] ", "- [x] ", "- [-] ", "> ", "> [!note] ",
                     "> [!tip]- ", "```", "```swift", "~~~", "    ", "\t", "---", "***", "___", "===", "|", "| a | b |", "|---|---|",
                     "**", "*", "_", "__", "~~", "==", "`", "``", "[", "]", "(", ")", "[[", "]]", "![", "![[x.png]]", "<", ">",
                     "<div>", "</div>", "<!-- c -->", "$", "$$", "%%", "\\", "&amp;", "https://x.y/z", "a@b.co", "word", "Word ",
                     "émoji 🎉", "日本語", " ", "  ", "\n", "\n\n", "\n\n\n", "1", "#tag", "^c1", "📅 2026-11-20", "[^1]", "[^1]: n"]
    /// The block as a reader sees it: list numbers after the first are display-only in Markdown,
    /// and blank lines at the very end of a file mean nothing.
    func meaning(_ block: Block) -> String {
        var kind = "\(block.kind)"
        if case .numbered(_, let delimiter) = block.kind { kind = "numbered \(delimiter)" }
        var text = block.plainText
        if case .raw = block.kind { while text.hasSuffix("\n") { text.removeLast() } }
        return "\(kind)|\(block.indent)|\(text)"
    }
    var random = SeededRandom(seed: 2026)
    var unstable: [String] = []
    var altered: [String] = []
    for _ in 0..<4000 {
        var text = ""
        for _ in 0..<(1 + random.next(below: 30)) { text += fragments[random.next(below: fragments.count)] }
        let document = MarkdownParser.parse(text)
        let written = MarkdownSerializer.serialize(document)
        let reread = MarkdownParser.parse(written)
        if MarkdownSerializer.serialize(reread) != written, unstable.count < 3 { unstable.append(text) }
        let same = document.frontMatter == reread.frontMatter && document.blocks.count == reread.blocks.count
            && zip(document.blocks, reread.blocks).allSatisfy { first, second in
                guard meaning(first) == meaning(second) else { return false }
                if case .raw = first.kind { return true }
                return InlineSerializer.isEquivalent(first.runs, second.runs)
            }
        if !same, altered.count < 3 { altered.append(text) }
    }
    check(unstable.isEmpty, "writing is stable for random documents; first cases: \(unstable.map(visible))")
    check(altered.isEmpty, "random documents keep their content when written; first cases: \(altered.map(visible))")
}

// MARK: - Fuzzing: realistic notes round-trip byte for byte

do {
    var random = SeededRandom(seed: 7)
    func pick(_ items: [String]) -> String { items[random.next(below: items.count)] }
    let words = ["plan", "Launch", "review", "the", "budget", "café", "日本語", "🎉", "v1.2", "3pm", "e-mail", "don't", "(draft)",
                 "a/b", "50%", "#tag", "#project/web"]
    let inline = ["**bold words**", "*italic*", "_italic_", "__bold__", "~~gone~~", "==marked==", "`code`", "`a * b`",
                  "[link](https://example.com)", "[[Wiki Page]]", "[[Wiki Page|alias]]", "https://example.com/x?y=1", "![[pic.png]]",
                  "**bold *nested* bold**", "<span>html</span>", "$x^2$", "[^1]", "\\*literal\\*", "1\\. not a list", "a_b_c", "2 * 3 * 4"]
    func sentence() -> String {
        (0..<(2 + random.next(below: 9))).map { _ in random.next(below: 4) == 0 ? pick(inline) : pick(words) }.joined(separator: " ")
    }
    func block() -> String {
        switch random.next(below: 16) {
        case 0: return "\(String(repeating: "#", count: 1 + random.next(below: 4))) \(sentence())"
        case 1, 2, 3: return sentence() + (random.next(below: 3) == 0 ? "\n" + sentence() : "")
        case 4: let marker = pick(["-", "*", "+"]); return (0..<(1 + random.next(below: 4))).map { _ in "\(marker) \(sentence())" }.joined(separator: "\n")
        case 5: return (1...(1 + random.next(below: 4))).map { "\($0). \(sentence())" }.joined(separator: "\n")
        case 6: return (0..<(1 + random.next(below: 4))).map { _ in "- [\(pick([" ", "x", " "]))] \(sentence())\(random.next(below: 2) == 0 ? " 📅 2026-11-2\(random.next(below: 9))" : "")" }.joined(separator: "\n")
        case 7: return "- \(sentence())\n  - \(sentence())\n    - \(sentence())\n- \(sentence())"
        case 8: return "- \(sentence())\n\t- \(sentence())\n- \(sentence())"
        case 9: return "> \(sentence())" + (random.next(below: 2) == 0 ? "\n> \(sentence())" : "")
        case 10: return "> [!\(pick(["note", "tip", "warning"]))]\(pick(["", "-", "+"])) \(sentence())\n> \(sentence())"
        case 11: return "```\(pick(["", "swift", "js"]))\nlet x = 1\n  indented()\n```"
        case 12: return pick(["---", "***", "___"])
        case 13: return "| \(pick(words)) | \(pick(words)) |\n|---|:---:|\n| \(pick(words)) | \(sentence()) |"
        case 14: return pick(["![[pic.png]]", "![alt text](images/pic.png)", "![[pic.png|320]]"])
        default: return "<div>\nHTML block\n</div>"
        }
    }
    var changed: [String] = []
    for _ in 0..<3000 {
        var text = random.next(below: 6) == 0 ? "---\ntitle: Test\ntags: [a, b]\n---\n" : ""
        for index in 0..<(1 + random.next(below: 10)) {
            if index > 0 { text += String(repeating: "\n", count: 2 + random.next(below: 2)) }
            text += block()
        }
        text += "\n"
        if MarkdownSerializer.serialize(MarkdownParser.parse(text)) != text, changed.count < 3 { changed.append(text) }
    }
    check(changed.isEmpty, "realistic notes write back byte for byte; first cases: \(changed.map(visible))")
}

// Numbered lists separated only by blank lines are one list in Markdown, but each keeps its numbers.
exact("1. a\n2. b\n\n1. c\n2. d\n")
exact("1. a\n\n\n1. b\n2. c\n")
exact("1. a\n\n2. b\n\n3. c\n")
exact("1. a\n1. b\n1. c\n")
do {
    var document = MarkdownParser.parse("1. a\n2. b\n3. c\n")
    document.blocks.remove(at: 1)
    check(MarkdownSerializer.serialize(document) == "1. a\n2. c\n", "removing an item renumbers the rest")
}
// A note that opens with a divider.
exact("---\n\nText after a divider\n")
exact("---\nSetext heading\n---\n")
do {
    let blocks = [Block(kind: .rule), Block.paragraph("key: value"), Block(kind: .rule)]
    let written = MarkdownSerializer.serialize(MarkdownDocument(blocks: blocks))
    let reread = MarkdownParser.parse(written)
    check(reread.frontMatter == nil && reread.blocks.count == 3, "a divider is never read back as front matter: \(visible(written))")
}

// MARK: - Details

do {
    let document = MarkdownParser.parse("5. five\n6. six\n\n- [x] done\n")
    if case .numbered(let number, _) = document.blocks[0].kind { check(number == 5, "list start is kept") }
    if case .numbered(let number, _) = document.blocks[1].kind { check(number == 6, "later items keep their own number") }
    check(document.blocks[2].kind.isChecked, "checked state")
}
do {
    let document = MarkdownParser.parse("---\nicon: 🌱\ntitle: \"Quoted\"\n---\nBody\n")
    check(document.frontMatter == "icon: 🌱\ntitle: \"Quoted\"", "front matter is captured")
    check(FrontMatter.value(for: "icon", in: document.frontMatter) == "🌱", "front matter value")
    check(FrontMatter.value(for: "title", in: document.frontMatter) == "Quoted", "quoted front matter value")
    check(FrontMatter.setting("🚀", for: "icon", in: document.frontMatter) == "icon: 🚀\ntitle: \"Quoted\"", "replace value")
    check(FrontMatter.setting(nil, for: "icon", in: "icon: 🌱") == nil, "removing the only key removes the block")
    check(FrontMatter.setting("x", for: "icon", in: nil) == "icon: x", "create front matter")
    check(FrontMatter.setting("2026-11-16", for: "date", in: "icon: 🌱") == "icon: 🌱\ndate: 2026-11-16", "append key")
}
do {
    let document = MarkdownParser.parse("> [!info] Title\n> Body\n")
    if case .callout(let type, _, let hasTitle) = document.blocks[0].kind {
        check(type == "info" && hasTitle, "callout header")
    } else {
        check(false, "expected a callout")
    }
    check(document.blocks[0].plainText == "Title\nBody", "callout text")
}
do {
    let document = MarkdownParser.parse("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 |\n")
    if case .table(let table) = document.blocks[0].kind {
        check(table.header == ["a", "b"] && table.rows == [["1", "2"], ["3", ""]], "table cells")
    } else {
        check(false, "expected a table")
    }
}
do {
    let text = MarkdownParser.parse("# T\n\nSome **bold** words.\n\n- item\n").plainText
    check(text == "T\nSome bold words.\nitem", "plain text extraction")
}

// MARK: - Link and image titles

do {
    // Quotes in a title used to gain a second escape each time the paragraph was written,
    // which ended the title early and broke the link.
    let source = #"See [the site](https://example.com "a \"quoted\" title") now."#
    let parsed = runs(source)
    check(parsed.first { $0.style.link != nil }?.style.link?.title == #"a "quoted" title"#, "a title is read without its escapes")
    check(InlineSerializer.serialize(parsed) == source, "and written with them once: \(InlineSerializer.serialize(parsed))")
    let single = InlineSerializer.serialize(runs(#"[x](https://example.com 'it\'s')"#))
    check(runs(single).first?.style.link?.title == "it's", "a single-quoted title keeps its wording: \(single)")
    check(InlineSerializer.serialize(runs(#"[x](u "C:\path")"#)) == #"[x](u "C:\path")"#, "a backslash that is no escape stays as it is")
    let trailing = [InlineRun(text: "x", style: InlineStyle(link: LinkInfo(destination: "u", title: #"ends\"#)))]
    let written = InlineSerializer.serialize(trailing)
    check(runs(written).first?.style.link?.title == #"ends\"#, "a title ending in a backslash: \(written)")
}
exact(#"![A diagram](diagram.png "the \"before\" state")"# + "\n")

// MARK: - Closing fences

do {
    // A fence-like line indented four columns is a line of code, not the end of the block.
    let source = "~~~\n    ~~~\nsecret\n~~~\n"
    let document = MarkdownParser.parse(source)
    check(document.blocks.count == 1, "one code block: \(document.blocks.map(\.kind))")
    check(document.blocks.first?.plainText == "    ~~~\nsecret", "the indented line is part of it: \(document.blocks.first?.plainText.debugDescription ?? "-")")
    exact(source)
    check(MarkdownParser.parse("```\ncode\n   ```\nafter\n").blocks.count == 2, "a closing fence may be indented up to three spaces")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
