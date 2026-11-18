//
//  render-widgets.swift
//
//  Draws LP's widgets with sample data, in light and dark, so they can be checked without
//  installing the extension (Xcode cannot preview macOS widgets). Run through
//  Scripts/render-widgets.sh, which compiles it together with the widget sources.
//

import AppKit
import SwiftUI
import WidgetKit

@MainActor
func render(_ name: String, family: WidgetFamily, dark: Bool, rendering: WidgetRenderingMode = .fullColor,
            to folder: URL, @ViewBuilder content: () -> some View) {
    // macOS widget sizes, including the system's 16 pt content margins.
    let size: CGSize = switch family {
    case .systemSmall: CGSize(width: 170, height: 170)
    case .systemLarge: CGSize(width: 364, height: 382)
    default: CGSize(width: 364, height: 170)
    }
    let accent = dark ? Color(red: 0x3B / 255, green: 0x8F / 255, blue: 0xF7 / 255) : Color(red: 0x1A / 255, green: 0x63 / 255, blue: 0xCC / 255)
    let view = content()
        .padding(16)
        .frame(width: size.width, height: size.height)
        .background(dark ? Color(white: 0.16) : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(12)
        .background(dark ? Color(white: 0.05) : Color(white: 0.9))
        .tint(accent)
        .accentColor(accent)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.widgetRenderingMode, rendering)
        .environment(\.isDrawingSnapshot, true)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    renderer.colorMode = .nonLinear
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { print("could not render \(name)"); return }
    try? png.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
}

@main
struct RenderWidgets {
    @MainActor
    static func main() {
        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A snapshot written by the app (LP_WIDGET_SNAPSHOT) can stand in for the sample day.
        let snapshot = CommandLine.arguments.count > 2
            ? (WidgetStore.load(from: URL(fileURLWithPath: CommandLine.arguments[2])) ?? .sample)
            : WidgetSnapshot.sample
        let today = TodayEntry(date: Date(), snapshot: snapshot, state: .ready)
        let board = BoardEntry(date: Date(), board: snapshot.boards.first, state: .ready)

        do {
            for dark in [false, true] {
                render("today-small", family: .systemSmall, dark: dark, to: folder) { TodayWidgetView(entry: today, size: .systemSmall) }
                render("today-medium", family: .systemMedium, dark: dark, to: folder) { TodayWidgetView(entry: today, size: .systemMedium) }
                render("today-large", family: .systemLarge, dark: dark, to: folder) { TodayWidgetView(entry: today, size: .systemLarge) }
                render("board-small", family: .systemSmall, dark: dark, to: folder) { BoardWidgetView(entry: board, size: .systemSmall) }
                render("board-medium", family: .systemMedium, dark: dark, to: folder) { BoardWidgetView(entry: board, size: .systemMedium) }
                render("setup-small", family: .systemSmall, dark: dark, to: folder) {
                    TodayWidgetView(entry: TodayEntry(date: Date(), snapshot: nil, state: .needsSetup), size: .systemSmall)
                }
                render("empty-medium", family: .systemMedium, dark: dark, to: folder) {
                    TodayWidgetView(entry: TodayEntry(date: Date(), snapshot: WidgetSnapshot(generated: Date(), workspace: "", items: [], events: [], boards: []), state: .ready), size: .systemMedium)
                }
            }
            // The desktop draws widgets in one tone when it is not in front.
            render("today-medium-vibrant", family: .systemMedium, dark: true, rendering: .vibrant, to: folder) { TodayWidgetView(entry: today, size: .systemMedium) }
        }
        print("rendered into \(folder.path)")
    }
}
