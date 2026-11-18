//
//  BoardWidget.swift
//  LPWidgets
//
//  How far along one board is: its progress, what is overdue and how its cards are spread
//  over its lists. The board is chosen when editing the widget; without a choice it follows
//  the board changed most recently.
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Choosing a board

struct BoardEntity: AppEntity {
    /// The board's path in the workspace.
    var id: String
    var title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Board" }
    static var defaultQuery: BoardEntityQuery { BoardEntityQuery() }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct BoardEntityQuery: EntityQuery {
    func entities(for identifiers: [BoardEntity.ID]) async throws -> [BoardEntity] {
        boards().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BoardEntity] {
        boards()
    }

    func defaultResult() async -> BoardEntity? {
        boards().first
    }

    private func boards() -> [BoardEntity] {
        (WidgetStore.load()?.boards ?? []).map { BoardEntity(id: $0.path, title: $0.title) }
    }
}

struct BoardWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Board" }
    static var description: IntentDescription { "Choose the board to follow." }

    @Parameter(title: "Board")
    var board: BoardEntity?
}

// MARK: - Timeline

struct BoardEntry: TimelineEntry {
    var date: Date
    var board: WidgetSnapshot.Board?
    var state: WidgetState
}

struct BoardProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> BoardEntry {
        BoardEntry(date: .now, board: WidgetSnapshot.sample.boards.first, state: .ready)
    }

    func snapshot(for configuration: BoardWidgetIntent, in context: Context) async -> BoardEntry {
        entry(for: configuration, at: .now, showingSampleIfEmpty: context.isPreview)
    }

    func timeline(for configuration: BoardWidgetIntent, in context: Context) async -> Timeline<BoardEntry> {
        // Overdue counts change at midnight; the app reloads the widget when the board changes.
        let now = Date()
        let tomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 60)
        let first = entry(for: configuration, at: now, showingSampleIfEmpty: false)
        var next = first
        next.date = tomorrow
        return Timeline(entries: [first, next], policy: .atEnd)
    }

    private func entry(for configuration: BoardWidgetIntent, at date: Date, showingSampleIfEmpty: Bool) -> BoardEntry {
        guard let snapshot = WidgetStore.load() else {
            if showingSampleIfEmpty { return BoardEntry(date: date, board: WidgetSnapshot.sample.boards.first, state: .ready) }
            return BoardEntry(date: date, board: nil, state: WidgetStore.isAvailable ? .waitingForApp : .needsSetup)
        }
        let chosen = configuration.board.flatMap { choice in snapshot.boards.first { $0.path == choice.id } }
        return BoardEntry(date: date, board: chosen ?? snapshot.boards.first, state: .ready)
    }
}

struct BoardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LPBoard", intent: BoardWidgetIntent.self, provider: BoardProvider()) { entry in
            BoardWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Board")
        .description("How far along one of your boards is.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Views

struct BoardWidgetView: View {
    let entry: BoardEntry
    /// Set when drawn outside a widget (snapshots); a widget reads its size from the environment.
    var size: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily

    var body: some View {
        if entry.state != .ready {
            WidgetMessage(state: entry.state, symbol: "rectangle.split.3x1")
        } else if let board = entry.board {
            switch size ?? environmentFamily {
            case .systemSmall:
                Progress(board: board, day: WidgetSnapshot.dayKey(entry.date))
                    .widgetURL(LPLink.open(board.path))
            default:
                HStack(alignment: .top, spacing: 16) {
                    Progress(board: board, day: WidgetSnapshot.dayKey(entry.date))
                        .frame(width: 128)
                    Lists(board: board)
                }
                .widgetURL(LPLink.open(board.path))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text("No boards yet")
                    .font(.headline)
                Text("Create a board in LP to follow its progress here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(LPLink.home)
        }
    }
}

private struct Progress: View {
    let board: WidgetSnapshot.Board
    let day: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if let icon = board.icon, !icon.isEmpty {
                    Text(icon)
                } else {
                    Image(systemName: "rectangle.split.3x1")
                        .foregroundStyle(.tint)
                }
                Text(board.title)
                    .lineLimit(2)
            }
            .font(.caption.weight(.semibold))

            Spacer(minLength: 6)

            Text("\(board.percent)%")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ProgressBar(fraction: board.fraction, height: 5)
                .padding(.top, 2)
                .accessibilityLabel("\(board.percent) percent done")
            Text("\(board.done) of \(board.total) done")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            let overdue = board.overdue(on: day)
            if overdue > 0 {
                Label("\(overdue) overdue", systemImage: "exclamationmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.lpCritical)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Each list with its number of cards and a bar for its share of the board.
private struct Lists: View {
    let board: WidgetSnapshot.Board

    var body: some View {
        let shown = Array(board.lists.prefix(5))
        let largest = max(1, shown.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, list in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(list.title)
                            .lineLimit(1)
                        if list.marksComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Cards here count as done")
                        }
                        Spacer(minLength: 4)
                        Text("\(list.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    ProgressBar(fraction: Double(list.count) / Double(largest), height: 3,
                                fill: list.marksComplete ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
            if board.lists.count > shown.count {
                Text("and \(board.lists.count - shown.count) more lists")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    BoardWidget()
} timeline: {
    BoardEntry(date: .now, board: WidgetSnapshot.sample.boards.first, state: .ready)
}

#Preview("Medium", as: .systemMedium) {
    BoardWidget()
} timeline: {
    BoardEntry(date: .now, board: WidgetSnapshot.sample.boards.first, state: .ready)
    BoardEntry(date: .now, board: nil, state: .needsSetup)
}
