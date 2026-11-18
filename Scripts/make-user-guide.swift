//
//  make-user-guide.swift
//
//  Turns docs/user-guide/guide.html into an A4 PDF with WebKit (the engine Safari prints with):
//  the first pass finds the page each chapter starts on, the second fills those numbers into the
//  contents page, and a last step adds page numbers and bookmarks. Run it through
//  Scripts/make-user-guide.sh.
//

import AppKit
import PDFKit
import WebKit

/// A4, in points. The margins match the guide's `@page` rule, which WebKit prints with; the page
/// number is drawn in the bottom one.
let paper = NSSize(width: 595.28, height: 841.89)
let margins = NSEdgeInsets(top: 46, left: 54, bottom: 62, right: 54)

struct Chapter {
    var number: Int
    var title: String
}

@MainActor
final class Printer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var loaded: CheckedContinuation<Void, Never>?
    private var printed: CheckedContinuation<Bool, Never>?

    override init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1200))
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ file: URL) async {
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
        // Let images decode before printing.
        try? await Task.sleep(for: .milliseconds(1200))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loaded?.resume()
            self.loaded = nil
        }
    }

    func run(_ script: String) async -> Any? {
        try? await webView.evaluateJavaScript(script)
    }

    func printPDF(to file: URL) async -> Bool {
        let info = NSPrintInfo()
        info.paperSize = paper
        // The stylesheet's @page margins apply; these would only add to them.
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        return await withCheckedContinuation { continuation in
            printed = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc private func printDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printed?.resume(returning: success)
        printed = nil
    }
}

/// The page (1-based) each "Chapter N" label first appears on, after the contents page.
func chapterPages(in file: URL) -> [Int: Int] {
    guard let document = PDFDocument(url: file) else { return [:] }
    var pages: [Int: Int] = [:]
    let pattern = try! NSRegularExpression(pattern: "(?i)chapter\\s+(\\d+)\\b")
    for index in 2..<document.pageCount {
        guard let text = document.page(at: index)?.string else { continue }
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text), let number = Int(text[range]), pages[number] == nil {
                pages[number] = index + 1
            }
        }
    }
    return pages
}

/// Draws the final PDF: every page with its number in the footer (not on the cover), the contents
/// rows linked to their chapters, and bookmarks. It is all done with Core Graphics: PDFKit's
/// writer (macOS 27) drops bookmarks and saves links without the page they point to.
func finish(_ source: URL, chapters: [Chapter], pages: [Int: Int], to output: URL) throws {
    guard let document = PDFDocument(url: source) else { throw CocoaError(.fileReadCorruptFile) }
    var box = CGRect(origin: .zero, size: paper)
    let info: [CFString: Any] = [
        kCGPDFContextTitle: "LP User Guide",
        kCGPDFContextSubject: "How to use LP (Local Productivity) for macOS",
        kCGPDFContextCreator: "LP",
    ]
    guard let context = CGContext(output as CFURL, mediaBox: &box, info as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }

    // Where each chapter's row sits on the contents page.
    var rows: [Int: CGRect] = [:]
    if let contents = document.page(at: 1) {
        for chapter in chapters {
            guard let title = document.findString(chapter.title, withOptions: []).first(where: { $0.pages.first == contents }) else { continue }
            let line = title.bounds(for: contents)
            rows[chapter.number] = CGRect(x: margins.left, y: line.minY - 6, width: paper.width - margins.left - margins.right, height: line.height + 12)
        }
    }

    let ink = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 0.55)
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5, weight: .medium), .foregroundColor: ink]
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { continue }
        context.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: context)
        if index > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "LP User Guide", attributes: attributes)
                .draw(at: NSPoint(x: margins.left, y: 30))
            let number = NSAttributedString(string: "\(index + 1)", attributes: attributes)
            number.draw(at: NSPoint(x: paper.width - margins.right - number.size().width, y: 30))
            NSGraphicsContext.restoreGraphicsState()
        }
        for chapter in chapters where pages[chapter.number] == index + 1 {
            context.addDestination("chapter-\(chapter.number)" as CFString, at: CGPoint(x: 0, y: paper.height))
        }
        if index == 1 {
            for (number, row) in rows {
                context.setDestination("chapter-\(number)" as CFString, for: row)
            }
        }
        context.endPDFPage()
    }

    let bookmarks: [[CFString: Any]] = chapters.compactMap { chapter in
        guard let page = pages[chapter.number] else { return nil }
        return [kCGPDFOutlineTitle: "\(chapter.number). \(chapter.title)", kCGPDFOutlineDestination: page]
    }
    CGPDFContextSetOutline(context, [kCGPDFOutlineChildren: bookmarks] as CFDictionary)
    context.closePDF()
}

@main
struct MakeUserGuide {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            print("Usage: make-user-guide <guide.html> <output.pdf>")
            exit(2)
        }
        let source = URL(fileURLWithPath: arguments[1])
        let output = URL(fileURLWithPath: arguments[2])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lp-guide-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let printer = Printer()
            await printer.load(source)
            let titles = await printer.run("JSON.stringify([...document.querySelectorAll('.chapter')].map(c => c.querySelector('h1').textContent))") as? String ?? "[]"
            let names = (try? JSONDecoder().decode([String].self, from: Data(titles.utf8))) ?? []
            let chapters = names.enumerated().map { Chapter(number: $0.offset + 1, title: $0.element) }

            // Pass 1 finds where chapters start; pass 2 prints the contents page with those numbers.
            var pages: [Int: Int] = [:]
            var file = scratch.appendingPathComponent("pass-1.pdf")
            for pass in 1...3 {
                file = scratch.appendingPathComponent("pass-\(pass).pdf")
                if !pages.isEmpty {
                    let fill = pages.map { "document.querySelector('[data-toc=\"\($0.key)\"] .p').textContent = '\($0.value)';" }.joined()
                    _ = await printer.run(fill)
                }
                guard await printer.printPDF(to: file) else {
                    print("Printing failed.")
                    exit(1)
                }
                let found = chapterPages(in: file)
                if found == pages { break }
                pages = found
            }
            do {
                try finish(file, chapters: chapters, pages: pages, to: output)
            } catch {
                print("Could not finish the PDF: \(error)")
                exit(1)
            }
            let count = PDFDocument(url: output)?.pageCount ?? 0
            print("Wrote \(output.path) — \(count) pages, \(chapters.count) chapters.")
            try? FileManager.default.removeItem(at: scratch)
            exit(0)
        }
        app.run()
    }
}
