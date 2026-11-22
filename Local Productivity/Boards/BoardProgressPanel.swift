//
//  BoardProgressPanel.swift
//  LP
//
//  The panel beside a board that answers "how is this going?": how much is done, where
//  the cards are, what needs attention, how it has moved over time, and what happened
//  recently, with ways to share or export it all.
//

import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Whether progress sharing is set up. Observable so the board updates the moment a token is
/// saved in Settings.
@Observable
final class SharingAccount {
    static let shared = SharingAccount()

    private(set) var hasToken: Bool
    /// The GitHub user the token belongs to, once it has been checked.
    var login: String?
    /// Where the person can end LP's access on GitHub (depends on how they connected).
    private(set) var accessPage: URL?
    /// Counts connects and disconnects, so a sign-in that began before one can't undo it.
    @ObservationIgnored private(set) var credentialChanges = 0

    init() {
        let saved = GistPublisher.token
        hasToken = saved != nil
        accessPage = saved.map(GitHubTokenPages.accessPage(forToken:))
    }

    func setToken(_ token: String?) throws {
        try GistPublisher.setToken(token)
        credentialChanges += 1
        let saved = GistPublisher.token
        hasToken = saved != nil
        accessPage = saved.map(GitHubTokenPages.accessPage(forToken:))
        if !hasToken { login = nil }
    }
}

struct BoardProgressPanel: View {

    let store: BoardStore
    @State private var showsTable = false

    var body: some View {
        let progress = store.progress
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headline(progress)
                lists(progress)
                stats(progress)
                trend
                activity
                ShareSection(store: store)
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lpSoftScrollEdge()
        .background(Color.lpCanvas)
    }

    // MARK: Headline

    private func headline(_ progress: BoardProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Progress")
                .font(.lp(size: 12, weight: .semibold))
                .foregroundStyle(Color.lpAccentText)
            Text("\(progress.percent)%")
                .font(.lp(size: 48, weight: .bold))
                .foregroundStyle(Color.lpInk)
            Text(progress.total == 0 ? "No cards yet" : "\(progress.done) of \(progress.total) \(progress.total == 1 ? "card" : "cards") done")
                .font(.lp(size: 13))
                .foregroundStyle(Color.lpInkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Lists

    private func lists(_ progress: BoardProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LaneProgressBar(progress: progress)
                .frame(height: 10)
            VStack(spacing: 6) {
                ForEach(Array(progress.perLane.enumerated()), id: \.offset) { index, lane in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(BoardPalette.lane(index, of: progress.perLane.count))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(lane.title)
                            .font(.lp(size: 12.5))
                            .foregroundStyle(Color.lpInk)
                            .lineLimit(1)
                        if lane.marksComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.lp(size: 10.5))
                                .foregroundStyle(BoardPalette.complete)
                                .accessibilityLabel("counts as done")
                        }
                        Spacer(minLength: 8)
                        Text("\(lane.count)")
                            .font(.lp(size: 12.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.lpInkSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.top, 20)
    }

    // MARK: Stats

    private func stats(_ progress: BoardProgress) -> some View {
        let averageDays = store.log.averageDaysToDone()
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                StatTile(label: "Overdue", value: "\(progress.overdue)",
                         symbol: progress.overdue > 0 ? "exclamationmark.circle.fill" : nil,
                         tint: progress.overdue > 0 ? Color.lpCritical : nil)
                StatTile(label: "Due in 3 days", value: "\(progress.dueSoon)",
                         symbol: progress.dueSoon > 0 ? "clock.fill" : nil,
                         tint: progress.dueSoon > 0 ? Color.lpWarning : nil)
            }
            GridRow {
                StatTile(label: "Done this week", value: "\(store.log.completedCount(withinDays: 7))")
                StatTile(label: "Time to done", value: averageDays.map { Self.days($0) } ?? "—")
            }
        }
        .padding(.top, 22)
    }

    private static func days(_ value: Double) -> String {
        if value < 1 { return "< 1 day" }
        let rounded = (value * 10).rounded() / 10
        return rounded == 1 ? "1 day" : "\(rounded.formatted(.number.precision(.fractionLength(0...1)))) days"
    }

    // MARK: Trend

    private var trend: some View {
        let snapshots = store.log.snapshots.suffix(30)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Over time")
                    .font(.lp(size: 11, weight: .semibold))
                    .foregroundStyle(Color.lpInkTertiary)
                Spacer()
                if snapshots.count >= 2 {
                    Button {
                        showsTable.toggle()
                    } label: {
                        Image(systemName: showsTable ? "chart.xyaxis.line" : "tablecells")
                            .font(.lp(size: 11, weight: .medium))
                            .foregroundStyle(Color.lpInkSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarButtonStyle())
                    .help(showsTable ? "Show as chart" : "Show as table")
                    .accessibilityLabel(showsTable ? "Show as chart" : "Show as table")
                }
            }
            if snapshots.count < 2 {
                Text("A chart of finished and total cards appears here once you’ve worked on this board on two different days.")
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInkTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showsTable {
                TrendTable(snapshots: Array(snapshots))
            } else {
                TrendChart(snapshots: Array(snapshots))
            }
        }
        .padding(.top, 26)
    }

    // MARK: Activity

    private var activity: some View {
        let recent = Array(store.log.events.suffix(10).reversed())
        return VStack(alignment: .leading, spacing: 8) {
            Text("Recent activity")
                .font(.lp(size: 11, weight: .semibold))
                .foregroundStyle(Color.lpInkTertiary)
            if recent.isEmpty {
                Text("Cards you add, move and finish are recorded here.")
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInkTertiary)
            }
            ForEach(recent) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: event.symbol)
                        .font(.lp(size: 11))
                        .foregroundStyle(event.kind == .completed ? Color.lpGood : Color.lpInkTertiary)
                        .accessibilityHidden(true)
                    Text(event.sentence)
                        .font(.lp(size: 12.5))
                        .foregroundStyle(Color.lpInk)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(event.at.compactRelative)
                        .font(.lp(size: 11))
                        .foregroundStyle(Color.lpInkTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 26)
    }
}

// MARK: - Stat tile

private struct StatTile: View {
    let label: String
    let value: String
    var symbol: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.lp(size: 11.5))
                .foregroundStyle(Color.lpInkSecondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.lp(size: 13))
                        .foregroundStyle(tint ?? Color.lpInkSecondary)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(.lp(size: 20, weight: .semibold))
                    .foregroundStyle(tint ?? Color.lpInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lpFillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Trend chart

private struct TrendPoint: Identifiable {
    let date: Date
    let done: Int
    let total: Int
    var id: Date { date }
}

/// Cards done (the point, in the accent) against all cards (context, in grey) over time.
private struct TrendChart: View {
    let snapshots: [BoardSnapshot]
    @State private var hovered: Date?

    private var points: [TrendPoint] {
        snapshots.map { TrendPoint(date: $0.day.date(), done: $0.done, total: $0.total) }
    }

    private func nearest(to date: Date) -> TrendPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    var body: some View {
        let points = points
        let last = points.last
        VStack(alignment: .leading, spacing: 8) {
            // The legend, carrying each series' latest value.
            HStack(spacing: 14) {
                LegendKey(color: .lpSeriesPrimary, label: "Done", value: last?.done)
                LegendKey(color: .lpSeriesContext, label: "Total", value: last?.total)
            }

            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Day", point.date, unit: .day), y: .value("Cards", point.done))
                        .foregroundStyle(Color.lpSeriesPrimary.opacity(0.10))
                        .interpolationMethod(.monotone)
                }
                ForEach(points) { point in
                    LineMark(x: .value("Day", point.date, unit: .day), y: .value("Cards", point.total),
                             series: .value("Series", "Total"))
                        .foregroundStyle(Color.lpSeriesContext)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                ForEach(points) { point in
                    LineMark(x: .value("Day", point.date, unit: .day), y: .value("Cards", point.done),
                             series: .value("Series", "Done"))
                        .foregroundStyle(Color.lpSeriesPrimary)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let last {
                    // End markers, ringed in the background colour so they stay clear of the lines.
                    PointMark(x: .value("Day", last.date, unit: .day), y: .value("Cards", last.total))
                        .symbolSize(90)
                        .foregroundStyle(Color.lpCanvas)
                    PointMark(x: .value("Day", last.date, unit: .day), y: .value("Cards", last.total))
                        .symbolSize(36)
                        .foregroundStyle(Color.lpSeriesContext)
                    PointMark(x: .value("Day", last.date, unit: .day), y: .value("Cards", last.done))
                        .symbolSize(90)
                        .foregroundStyle(Color.lpCanvas)
                    PointMark(x: .value("Day", last.date, unit: .day), y: .value("Cards", last.done))
                        .symbolSize(36)
                        .foregroundStyle(Color.lpSeriesPrimary)
                }
                if let hovered, let point = nearest(to: hovered) {
                    RuleMark(x: .value("Day", point.date, unit: .day))
                        .foregroundStyle(Color.lpInkTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            TrendTooltip(point: point)
                        }
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: 0...max(1, (points.map(\.total).max() ?? 1)))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Color.lpHairline)
                    AxisValueLabel()
                        .font(.lp(size: 10))
                        .foregroundStyle(Color.lpInkTertiary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.lp(size: 10))
                        .foregroundStyle(Color.lpInkTertiary)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plot = proxy.plotFrame else { return }
                                let x = location.x - geometry[plot].origin.x
                                hovered = proxy.value(atX: x, as: Date.self)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Cards done and total cards over time")
            .accessibilityValue(summary)
        }
    }

    private var summary: String {
        guard let first = points.first, let last = points.last else { return "" }
        return "From \(first.done) of \(first.total) done on \(first.date.formatted(.dateTime.month().day())) to \(last.done) of \(last.total) done on \(last.date.formatted(.dateTime.month().day()))"
    }
}

/// A legend entry: a short line in the series colour, the name, and the latest value.
private struct LegendKey: View {
    let color: Color
    let label: String
    let value: Int?

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 2.5)
                .accessibilityHidden(true)
            Text(label)
                .font(.lp(size: 11.5))
                .foregroundStyle(Color.lpInkSecondary)
            if let value {
                Text("\(value)")
                    .font(.lp(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.lpInk)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The hover readout: the values lead, each keyed by a short line in its series colour.
private struct TrendTooltip: View {
    let point: TrendPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(point.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.lp(size: 10.5))
                .foregroundStyle(Color.lpInkSecondary)
            row(value: point.done, label: "done", color: .lpSeriesPrimary)
            row(value: point.total, label: "total", color: .lpSeriesContext)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.lpSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.lpHairline))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private func row(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 10, height: 2.5)
            Text("\(value)")
                .font(.lp(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.lpInk)
            Text(label)
                .font(.lp(size: 11))
                .foregroundStyle(Color.lpInkSecondary)
        }
    }
}

/// The same numbers as the chart, as a table.
private struct TrendTable: View {
    let snapshots: [BoardSnapshot]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("Day")
                Text("Done").gridColumnAlignment(.trailing)
                Text("Total").gridColumnAlignment(.trailing)
            }
            .font(.lp(size: 11, weight: .semibold))
            .foregroundStyle(Color.lpInkTertiary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(snapshots.reversed().prefix(14), id: \.day) { snapshot in
                GridRow {
                    Text(snapshot.day.shortTitle)
                        .foregroundStyle(Color.lpInkSecondary)
                    Text("\(snapshot.done)")
                    Text("\(snapshot.total)")
                }
                .font(.lp(size: 12))
                .monospacedDigit()
            }
        }
        .foregroundStyle(Color.lpInk)
    }
}

// MARK: - Sharing

private struct ShareSection: View {
    let store: BoardStore
    @State private var confirmingStop = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share")
                .font(.lp(size: 11, weight: .semibold))
                .foregroundStyle(Color.lpInkTertiary)

            if let share = store.share {
                if store.shareIsTrusted {
                    shared(share)
                } else {
                    setUpElsewhere(share)
                }
            } else {
                Text("Publish a live progress page anyone with the link can open, on any device — free, from your own Google Drive (a Google Doc) or GitHub (a secret gist). It shows lists, card titles, due dates, tags and recent activity. Card notes stay private.")
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                let destinations = SharingServices.destinations
                if let only = destinations.first, destinations.count == 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button {
                                Task { await store.publish(to: only) }
                            } label: {
                                Label("Share Progress", systemImage: "link")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isPublishing)
                            .accessibilityHint(SharingServices.title(of: only))
                            if store.isPublishing { ProgressView().controlSize(.small) }
                        }
                        Text(SharingServices.title(of: only))
                            .font(.lp(size: 11.5))
                            .foregroundStyle(Color.lpInkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !destinations.isEmpty {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(destinations, id: \.self) { destination in
                                Button(SharingServices.title(of: destination)) {
                                    Task { await store.publish(to: destination) }
                                }
                            }
                        } label: {
                            Label("Share Progress", systemImage: "link")
                        }
                        .fixedSize()
                        .disabled(store.isPublishing)
                        .accessibilityHint("Choose where the page goes: Google Drive or GitHub")
                        if store.isPublishing { ProgressView().controlSize(.small) }
                    }
                } else {
                    SettingsLink {
                        Text("Set Up Sharing…")
                    }
                    .simultaneousGesture(TapGesture().onEnded { SettingsView.select(.sharing) })
                }
            }

            Button {
                exportReport()
            } label: {
                Label("Export Report…", systemImage: "square.and.arrow.up")
                    .font(.lp(size: 12.5))
            }
            .buttonStyle(.link)
            .padding(.top, 2)
        }
        .padding(.top, 28)
        .confirmationDialog("Stop sharing this board?", isPresented: $confirmingStop) {
            Button("Stop Sharing", role: .destructive) {
                Task { await store.stopSharing() }
            }
        } message: {
            Text(store.share?.service == .googleDrive
                 ? "The progress page is deleted from your Google Drive and its link stops working."
                 : "The progress page is deleted from GitHub and its link stops working.")
        }
    }

    @ViewBuilder
    private func shared(_ share: BoardShare) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(Color.lpAccentText)
                    .accessibilityHidden(true)
                Text(share.pageURL?.absoluteString.replacingOccurrences(of: "https://", with: "") ?? "—")
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lpFillSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(SharingServices.whereItLives(share))
                .font(.lp(size: 11.5))
                .foregroundStyle(Color.lpInkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !SharingServices.isReady(share) {
                // Its GitHub token or Google account isn't here any more: say so, and what to do.
                Text(share.service == .googleDrive
                     ? "Its Google account isn’t connected on this Mac, so the page can’t be updated from here. Stop Sharing lets go of it."
                     : "GitHub isn’t connected on this Mac, so the page can’t be updated from here. Connect it in Settings → Sharing.")
                    .font(.lp(size: 11.5))
                    .foregroundStyle(Color.lpWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy Link") {
                    guard let link = share.pageURL else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                }
                // Always the page on GitHub or Google Docs, built from its ID (see `BoardShare.pageURL`).
                Button("Open") { if let link = share.pageURL { NSWorkspace.shared.open(link) } }
                Spacer()
                if store.isPublishing { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)

            Toggle("Keep up to date automatically", isOn: Binding(
                get: { share.updatesAutomatically },
                set: { store.setUpdatesAutomatically($0) }
            ))
            .font(.lp(size: 12))
            .toggleStyle(.checkbox)

            HStack(spacing: 6) {
                if let published = share.lastPublished {
                    Text("Updated \(published.inlineRelative)")
                        .font(.lp(size: 11.5))
                        .foregroundStyle(Color.lpInkTertiary)
                }
                Spacer()
                Button("Update Now") { Task { await store.updateSharedPage() } }
                    .buttonStyle(.link)
                    .font(.lp(size: 11.5))
                    .disabled(store.isPublishing)
                Text("·").foregroundStyle(Color.lpInkFaint)
                Button("Stop Sharing") { confirmingStop = true }
                    .buttonStyle(.link)
                    .font(.lp(size: 11.5))
                    .foregroundStyle(Color.lpCritical)
            }
        }
    }

    /// A shared page recorded in the folder but not published from this Mac — on another Mac, or
    /// by whoever the folder came from. Nothing is sent to it, or deleted, until the person allows.
    @ViewBuilder
    private func setUpElsewhere(_ share: BoardShare) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This board’s progress page was set up somewhere else — on another Mac, or by whoever this folder came from. LP won’t update it from here unless you allow it.")
                .font(.lp(size: 12))
                .foregroundStyle(Color.lpInkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let link = share.pageURL {
                Text(link.absoluteString.replacingOccurrences(of: "https://", with: ""))
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Keep It Updated From Here") { store.trustShare() }
                    .disabled(share.pageURL == nil || !SharingServices.isReady(share))
                Button("Forget It") { store.forgetShare() }
            }
            .controlSize(.small)
            if share.pageURL != nil, !SharingServices.isReady(share) {
                // Say why the first button can't be used yet, and where to fix it.
                VStack(alignment: .leading, spacing: 2) {
                    Text(share.service == .googleDrive
                         ? "To keep it updated from here, connect its Google account (\(SharingServices.accountName(share.account ?? ""))) and allow Google Drive first."
                         : "To keep it updated from here, connect GitHub first.")
                        .font(.lp(size: 11.5))
                        .foregroundStyle(Color.lpInkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsLink {
                        Text("Set Up Sharing…")
                    }
                    .buttonStyle(.link)
                    .font(.lp(size: 11.5))
                    .simultaneousGesture(TapGesture().onEnded { SettingsView.select(.sharing) })
                }
            }
        }
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.title = "Export Progress Report"
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (Workspace.sanitized(store.title) ?? "Board") + " — Progress.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportHTML(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            store.shareError = "Couldn’t export the report: \(error.localizedDescription)"
        }
    }
}
