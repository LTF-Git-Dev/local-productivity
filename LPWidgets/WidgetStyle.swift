//
//  WidgetStyle.swift
//  LPWidgets
//
//  Colours and small pieces shared by LP's widgets, following the app's design system:
//  system type, the accent for progress, the critical colour only for what is overdue.
//

import AppKit
import SwiftUI
import WidgetKit

extension Color {
    /// The design system's critical red, readable on light and dark backgrounds.
    static let lpCritical = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.706, green: 0.137, blue: 0.094, alpha: 1)
    })

    /// "#RRGGBB", or the accent when missing.
    init(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else {
            self = .accentColor
            return
        }
        self = Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

/// A thin rounded bar, used for a board's progress and its lists.
struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4
    var fill: AnyShapeStyle = AnyShapeStyle(.tint)

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * min(max(fraction, 0), 1)))
                        .widgetAccentable()
                }
        }
        .frame(height: height)
    }
}

extension EnvironmentValues {
    /// True when a widget is drawn into an image for checking, where links cannot be drawn.
    @Entry var isDrawingSnapshot = false
}

/// A link to part of LP. Widgets need `Link` for taps; a snapshot image draws the content alone.
struct WidgetLink<Content: View>: View {
    let destination: URL
    @ViewBuilder let content: Content
    @Environment(\.isDrawingSnapshot) private var isDrawingSnapshot

    var body: some View {
        if isDrawingSnapshot {
            content
        } else {
            Link(destination: destination) { content }
        }
    }
}

/// Why a widget has nothing to show yet.
enum WidgetState {
    case ready
    /// The app has not written anything yet.
    case waitingForApp
    /// LP is signed without a team, so it cannot share data with its widgets.
    case needsSetup
}

/// Shown instead of content when there is none yet.
struct WidgetMessage: View {
    let state: WidgetState
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
            Text(state == .needsSetup ? "Widgets need setting up" : "Open LP")
                .font(.headline)
            Text(state == .needsSetup
                 ? "LP has to be signed with your Apple ID team to share your day with widgets. See “Widgets” in LP’s README."
                 : "Your tasks, events and boards show here once LP has opened your workspace.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(LPLink.home)
    }
}

/// "9:30" or "9:30 AM", as the reader's settings write times.
func timeText(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

func timeText(minutes: Int, on date: Date) -> String {
    let start = Calendar.current.startOfDay(for: date)
    return timeText(start.addingTimeInterval(Double(minutes) * 60))
}
