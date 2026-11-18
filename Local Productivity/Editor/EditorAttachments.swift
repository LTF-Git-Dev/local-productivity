//
//  EditorAttachments.swift
//  Local Productivity
//
//  Blocks that are not text — dividers, images and tables — sit in the text as a
//  single attachment character. The attachment measures itself against the width of
//  the column and draws itself, so these blocks flow, scroll and select like any
//  other paragraph.
//

import AppKit
import ImageIO

nonisolated final class BlockAttachment: NSTextAttachment {

    enum Content: Equatable {
        case divider
        case image(ImageInfo)
        case table(TableInfo)
    }

    private(set) var content: Content
    var theme: EditorTheme
    /// Where an image's file was found, if it was.
    var imageURL: URL?
    /// Set by the text view while the block is selected.
    var isSelected = false

    private var loadedImage: NSImage?
    private var didAttemptLoad = false
    private var tableLayout: (width: CGFloat, layout: TableLayout)?

    init(content: Content, theme: EditorTheme, imageURL: URL? = nil) {
        self.content = content
        self.theme = theme
        self.imageURL = imageURL
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(_ content: Content) {
        self.content = content
        tableLayout = nil
        loadedImage = nil
        didAttemptLoad = false
    }

    // MARK: Measuring

    func size(fitting available: CGFloat) -> NSSize {
        switch content {
        case .divider:
            return NSSize(width: available, height: 17)

        case .image(let info):
            guard let image = photo else {
                return NSSize(width: min(available, 420), height: 64)
            }
            var width = min(image.size.width, available)
            if let hint = info.width { width = min(CGFloat(hint), available) }
            width = max(width, 24)
            var height = width * image.size.height / max(image.size.width, 1)
            let tallest: CGFloat = 760
            if height > tallest {
                height = tallest
                width = height * image.size.width / max(image.size.height, 1)
            }
            return NSSize(width: width.rounded(), height: height.rounded())

        case .table(let table):
            return layout(for: table, width: available).size
        }
    }

    private var photo: NSImage? {
        if !didAttemptLoad {
            didAttemptLoad = true
            if let imageURL, imageURL.isFileURL { loadedImage = ImageLoader.image(at: imageURL) }
        }
        return loadedImage
    }

    private func layout(for table: TableInfo, width: CGFloat) -> TableLayout {
        if let cached = tableLayout, abs(cached.width - width) < 0.5 { return cached.layout }
        let layout = TableLayout(table: table, width: width, theme: theme)
        tableLayout = (width, layout)
        return layout
    }

    // MARK: Drawing

    /// Draws the block into `rect`, in the flipped coordinates of the text view.
    func draw(in rect: NSRect) {
        switch content {
        case .divider:
            let line = NSRect(x: rect.minX, y: (rect.midY - 0.5).rounded(), width: rect.width, height: 1)
            (isSelected ? NSColor.controlAccentColor : NSColor.lpInkFaint).setFill()
            NSBezierPath(roundedRect: line, xRadius: 0.5, yRadius: 0.5).fill()

        case .image:
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            if let photo {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                photo.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high.rawValue])
                NSGraphicsContext.restoreGraphicsState()
                NSColor.lpHairline.setStroke()
                shape.lineWidth = 1
                shape.stroke()
            } else {
                NSColor.lpFillSubtle.setFill()
                shape.fill()
                Self.drawPlaceholder(placeholderText, in: rect)
            }
            if isSelected {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
                ring.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            }

        case .table(let table):
            layout(for: table, width: rect.width).draw(in: rect, isSelected: isSelected)
        }
    }

    private var placeholderText: String {
        guard case .image(let info) = content else { return "" }
        let name = info.source.split(separator: "/").last.map(String.init) ?? info.source
        if info.source.hasPrefix("http") { return info.alt.isEmpty ? name : info.alt }
        return "Image not found — \(name)"
    }

    private static func drawPlaceholder(_ text: String, in rect: NSRect) {
        let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.lpInkTertiary])))
        let iconSize = symbol?.size ?? .zero
        let iconRect = NSRect(x: rect.minX + 18, y: rect.midY - iconSize.height / 2, width: iconSize.width, height: iconSize.height)
        symbol?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.lpInkSecondary, .paragraphStyle: style
        ])
        let height = label.size().height
        label.draw(in: NSRect(x: iconRect.maxX + 10, y: rect.midY - height / 2, width: rect.width - iconRect.maxX - 26, height: height))
    }
}

/// TextKit 1 lays out and draws attachments through a cell. This one simply defers to the attachment.
final class BlockAttachmentCell: NSTextAttachmentCell {

    private nonisolated var block: BlockAttachment? { attachment as? BlockAttachment }

    nonisolated override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                                        glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let block else { return .zero }
        return NSRect(origin: .zero, size: block.size(fitting: max(80, lineFrag.width - position.x)))
    }

    nonisolated override func cellSize() -> NSSize {
        block?.size(fitting: 640) ?? .zero
    }

    nonisolated override func cellBaselineOffset() -> NSPoint {
        .zero
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        block?.draw(in: cellFrame)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        block?.draw(in: cellFrame)
    }

    override func wantsToTrackMouse() -> Bool {
        false
    }
}

// MARK: - Tables

/// A measured table, ready to draw: column widths, row heights and styled cell text.
nonisolated struct TableLayout {

    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 8

    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]
    let cells: [[NSAttributedString]]
    let size: NSSize

    init(table: TableInfo, width: CGFloat, theme: EditorTheme) {
        let columns = max(table.columnCount, 1)
        let fontSize = (theme.bodySize - 1.5)
        let rows = [table.header] + table.rows

        var styled: [[NSAttributedString]] = []
        for (rowIndex, row) in rows.enumerated() {
            var line: [NSAttributedString] = []
            for column in 0..<columns {
                let source = column < row.count ? row[column] : ""
                let alignment = column < table.alignments.count ? table.alignments[column] : .none
                line.append(InlineDisplay.attributedString(
                    for: InlineParser.parse(source.replacingOccurrences(of: "<br>", with: "\n")),
                    size: fontSize, weight: rowIndex == 0 ? .semibold : .regular, typeface: theme.typeface,
                    color: .lpInk, alignment: alignment
                ))
            }
            styled.append(line)
        }
        cells = styled

        // Columns share the width in proportion to what their content wants.
        var natural = Array(repeating: CGFloat(56), count: columns)
        for row in styled {
            for (column, cell) in row.enumerated() {
                natural[column] = max(natural[column], min(ceil(cell.size().width), 340) + Self.horizontalPadding * 2)
            }
        }
        let total = natural.reduce(0, +)
        let widths = natural.map { max(48, ($0 / max(total, 1) * width).rounded(.down)) }
        columnWidths = widths

        rowHeights = styled.map { row in
            var height: CGFloat = 0
            for (column, cell) in row.enumerated() {
                let box = cell.boundingRect(
                    with: NSSize(width: widths[column] - Self.horizontalPadding * 2, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                height = max(height, ceil(box.height))
            }
            return max(34, height + Self.verticalPadding * 2)
        }
        size = NSSize(width: widths.reduce(0, +), height: rowHeights.reduce(0, +))
    }

    func draw(in rect: NSRect, isSelected: Bool) {
        let frame = NSRect(origin: rect.origin, size: size).insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()

        // Header band and rules first, so that drawing text cannot disturb their colour.
        if let header = rowHeights.first {
            NSColor.lpFillSubtle.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: size.width, height: header)).fill()
        }
        NSColor.lpHairline.setFill()
        var ruleY = rect.minY
        for height in rowHeights.dropLast() {
            ruleY += height
            NSBezierPath(rect: NSRect(x: rect.minX, y: ruleY.rounded() - 0.5, width: size.width, height: 1)).fill()
        }
        var ruleX = rect.minX
        for width in columnWidths.dropLast() {
            ruleX += width
            NSBezierPath(rect: NSRect(x: ruleX.rounded() - 0.5, y: rect.minY, width: 1, height: size.height)).fill()
        }

        var y = rect.minY
        for (index, height) in rowHeights.enumerated() {
            var x = rect.minX
            for (column, width) in columnWidths.enumerated() {
                let cell = cells[index][column]
                let box = NSRect(x: x + Self.horizontalPadding, y: y + Self.verticalPadding,
                                 width: width - Self.horizontalPadding * 2, height: height - Self.verticalPadding * 2)
                let textHeight = ceil(cell.boundingRect(with: NSSize(width: box.width, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
                cell.draw(with: NSRect(x: box.minX, y: box.minY + max(0, (box.height - textHeight) / 2), width: box.width, height: textHeight),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
                x += width
            }
            y += height
        }
        NSGraphicsContext.restoreGraphicsState()

        (isSelected ? NSColor.controlAccentColor : NSColor.lpHairline).setStroke()
        outline.lineWidth = isSelected ? 2 : 1
        outline.stroke()
    }
}

// MARK: - Styled text outside the editor

/// Builds display-only attributed text from inline runs, for table cells.
nonisolated enum InlineDisplay {

    static func attributedString(for runs: [InlineRun], size: CGFloat, weight: NSFont.Weight,
                                 typeface: EditorTheme.Typeface, color: NSColor,
                                 alignment: TableInfo.Alignment = .none) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        switch alignment {
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        let design: NSFontDescriptor.SystemDesign = typeface == .serif ? .serif : typeface == .mono ? .monospaced : .default

        let result = NSMutableAttributedString()
        for run in runs {
            let style = run.style
            let isMono = style.code || style.raw
            let font = EditorTheme.font(
                size: isMono ? size * 0.9 : size,
                weight: style.bold != nil ? .semibold : weight,
                design: isMono ? .monospaced : design,
                italic: style.italic != nil
            )
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if style.link != nil || style.wikiLink != nil { attributes[.foregroundColor] = NSColor.controlAccentColor }
            if style.raw { attributes[.foregroundColor] = NSColor.lpInkSecondary }
            if style.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = NSColor.lpInkTertiary
            }
            if style.highlight { attributes[.backgroundColor] = NSColor.lpHighlight }
            if style.code { attributes[.backgroundColor] = NSColor.lpFillInlineCode }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: " ", attributes: [
                .font: EditorTheme.font(size: size, weight: weight, design: design, italic: false), .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}

// MARK: - Image loading

nonisolated enum ImageLoader {

    private static let cache = NSCache<NSURL, NSImage>()

    /// Loads an image for display, downsampled so very large photos stay cheap to draw.
    static func image(at url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = decode(url) ?? NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    static func forget(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    private static func decode(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? CGFloat, pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2600
        ]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // Screenshots taken on Retina displays carry 144 dpi; show them at their intended point size.
        let dpi = properties?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        let density = max(1, (dpi / 72).rounded())
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let isRotated = orientation >= 5
        let width = (isRotated ? pixelHeight : pixelWidth) / density
        let height = (isRotated ? pixelWidth : pixelHeight) / density
        return NSImage(cgImage: bitmap, size: NSSize(width: width, height: height))
    }
}
