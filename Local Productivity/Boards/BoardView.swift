//
//  BoardView.swift
//  LP
//
//  The board itself: lists side by side, cards that can be dragged within and between
//  lists, a header showing how far along the board is, and an optional progress panel.
//  Every drag has a keyboard, menu and VoiceOver alternative ("Move to…").
//

import SwiftUI
import UniformTypeIdentifiers

/// Colours for a board's lists. Lists are stages in order (To do → Done), so they share one
/// hue that deepens with each stage: an ordinal ramp, validated for step separation and
/// contrast in both modes. The stage nearest done is always the one furthest from the
/// background.
enum BoardPalette {

    // Steps of the blue ramp, lightest to darkest.
    private static let light: [Int: [UInt32]] = [
        1: [0x2A78D6],
        2: [0x6DA7EC, 0x184F95],
        3: [0x86B6EF, 0x2A78D6, 0x104281],
        4: [0x86B6EF, 0x3987E5, 0x1C5CAB, 0x0D366B],
        5: [0x86B6EF, 0x5598E7, 0x2A78D6, 0x1C5CAB, 0x104281]
    ]
    // Dark mode runs the other way: from the step nearest the dark surface to the lightest.
    private static let dark: [Int: [UInt32]] = [
        1: [0x3987E5],
        2: [0x256ABF, 0x9EC5F4],
        3: [0x184F95, 0x3987E5, 0x9EC5F4],
        4: [0x184F95, 0x2A78D6, 0x6DA7EC, 0xB7D3F6],
        5: [0x184F95, 0x256ABF, 0x3987E5, 0x6DA7EC, 0xB7D3F6],
        6: [0x184F95, 0x256ABF, 0x3987E5, 0x6DA7EC, 0x9EC5F4, 0xCDE2FB]
    ]
    /// Every step, for boards with more lists than the validated ramps hold. Their colours sit
    /// closer together, so order, the gaps between segments and the legend carry the difference.
    private static let fullLight: [UInt32] = [0x86B6EF, 0x6DA7EC, 0x5598E7, 0x3987E5, 0x2A78D6, 0x256ABF, 0x1C5CAB, 0x184F95, 0x104281, 0x0D366B]
    private static let fullDark: [UInt32] = [0x184F95, 0x1C5CAB, 0x256ABF, 0x2A78D6, 0x3987E5, 0x5598E7, 0x6DA7EC, 0x86B6EF, 0x9EC5F4, 0xB7D3F6, 0xCDE2FB]

    static func lane(_ index: Int, of count: Int) -> Color {
        Color(nsColor: .adaptive(light: NSColor(hex: step(index, count, light, fullLight)),
                                 dark: NSColor(hex: step(index, count, dark, fullDark))))
    }

    private static func step(_ index: Int, _ count: Int, _ ramps: [Int: [UInt32]], _ full: [UInt32]) -> UInt32 {
        let count = max(count, 1)
        let index = min(max(index, 0), count - 1)
        if let ramp = ramps[count] { return ramp[index] }
        let position = count == 1 ? 0 : Double(index) / Double(count - 1)
        return full[Int((position * Double(full.count - 1)).rounded())]
    }

    /// Done, as a status: green, always with a check mark.
    static let complete = Color.lpGood

    /// A stable colour for a tag's dot, so the same tag always looks the same. The tag's text
    /// stays in the ink colour; the dot carries the identity.
    static func tag(_ tag: String) -> Color {
        let hues: [(UInt32, UInt32)] = [(0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70), (0xEDA100, 0xC98500),
                                        (0xE87BA4, 0xD55181), (0x008300, 0x008300), (0x6250D6, 0x9085E9), (0xE34948, 0xE66767)]
        let seed = tag.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        let (light, dark) = hues[abs(seed) % hues.count]
        return Color(nsColor: .adaptive(light: NSColor(hex: light), dark: NSColor(hex: dark)))
    }
}

/// A card being dragged within the board. The drag is tracked by the app itself rather than the
/// system drag service, so it behaves the same on every supported macOS and moves exactly where
/// the pointer is.
@Observable
final class BoardCardDrag {
    static let space = "board"

    private(set) var cardID: String?
    /// Where the pointer is, in the board's coordinate space.
    private(set) var location: CGPoint = .zero
    /// The pointer's offset from the card's top-left corner when it was picked up.
    private(set) var grabOffset: CGSize = .zero
    private(set) var cardSize: CGSize = .zero
    private(set) var target: BoardDropTarget?

    @ObservationIgnored var cardFrames: [String: CGRect] = [:]
    @ObservationIgnored var laneFrames: [String: CGRect] = [:]

    var isActive: Bool { cardID != nil }

    func update(_ card: BoardCard, start: CGPoint, location: CGPoint, board: Board) {
        if cardID == nil, let frame = cardFrames[card.id] {
            cardID = card.id
            grabOffset = CGSize(width: start.x - frame.minX, height: start.y - frame.minY)
            cardSize = frame.size
        }
        self.location = location
        let lanes = board.lanes.compactMap { lane -> BoardDropTarget.Lane? in
            guard let frame = laneFrames[lane.id] else { return nil }
            return BoardDropTarget.Lane(id: lane.id, frame: frame,
                                        cards: lane.cards.compactMap { card in cardFrames[card.id].map { (card.id, $0) } })
        }
        let found = BoardDropTarget.find(at: location, in: lanes, dragging: card.id)
        if found != target { target = found }
    }

    /// Ends the drag and returns where the card should go.
    func finish() -> (cardID: String, target: BoardDropTarget)? {
        defer {
            cardID = nil
            target = nil
        }
        guard let cardID, let target else { return nil }
        return (cardID, target)
    }
}

private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct LaneFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this view's frame in the board's coordinate space under `key`.
    fileprivate func reportsBoardFrame<Key: PreferenceKey>(_ key: Key.Type, id: String) -> some View
        where Key.Value == [String: CGRect] {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: key, value: [id: geometry.frame(in: .named(BoardCardDrag.space))])
            }
        }
    }
}

struct BoardView: View {

    @Bindable var store: BoardStore
    var showsProgress: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which edges have more board beyond them, to show a fade there.
    @State private var overflow = Overflow()
    @State private var drag = BoardCardDrag()

    private struct Overflow: Equatable {
        var leading = false
        var trailing = false
    }

    var body: some View {
        GeometryReader { proxy in
            let sideBySide = proxy.size.width >= BoardLayout.sideBySideWidth
            let panelBeside = showsProgress && sideBySide
            HStack(spacing: 0) {
                lists(width: proxy.size.width - (panelBeside ? BoardLayout.panelWidth + 1 : 0))
                if panelBeside {
                    Rectangle().fill(Color.lpHairline).frame(width: 1)
                    BoardProgressPanel(store: store)
                        .frame(width: BoardLayout.panelWidth)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                // In a narrow window the panel floats over the board rather than squeezing it.
                if showsProgress, !sideBySide {
                    BoardProgressPanel(store: store)
                        .frame(width: min(BoardLayout.panelWidth, proxy.size.width - 32))
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous).strokeBorder(Color.lpHairline))
                        .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
                        .padding(12)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Color.lpCanvas)
        .animation(.lpSmooth, value: showsProgress)
        .sheet(item: $store.openedCard) { open in
            // The board's own undo manager, so card edits stay undoable after the sheet closes.
            CardDetailView(store: store, cardID: open.id, undoManager: undoManager)
        }
        .alert("Couldn’t Share", isPresented: Binding(get: { store.shareError != nil }, set: { if !$0 { store.shareError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.shareError ?? "")
        }
    }
}

extension BoardView {
    /// The scrolling board: header, then the lists at a width that suits the space.
    fileprivate func lists(width: CGFloat) -> some View {
        let laneWidth = BoardLayout.laneWidth(available: width, lanes: store.board.lanes.count)
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                BoardHeader(store: store)
                    .padding(.horizontal, BoardLayout.margin)
                    .padding(.top, 28)
                    .padding(.bottom, 22)

                HStack(alignment: .top, spacing: BoardLayout.spacing) {
                    ForEach(Array(store.board.lanes.enumerated()), id: \.element.id) { index, lane in
                        LaneView(lane: lane, index: index, width: laneWidth, store: store, drag: drag) { card in
                            store.openedCard = BoardStore.OpenedCard(id: card.id)
                        }
                    }
                    AddLaneButton(store: store)
                }
                .padding(.horizontal, BoardLayout.margin)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .coordinateSpace(.named(BoardCardDrag.space))
            .onPreferenceChange(CardFramesKey.self) { frames in drag.cardFrames = frames }
            .onPreferenceChange(LaneFramesKey.self) { frames in drag.laneFrames = frames }
            .overlay(alignment: .topLeading) { floatingCard }
        }
        .lpSoftScrollEdge()
        .onScrollGeometryChange(for: Overflow.self) { geometry in
            let x = geometry.contentOffset.x + geometry.contentInsets.leading
            return Overflow(leading: x > 1, trailing: x + geometry.containerSize.width < geometry.contentSize.width - 1)
        } action: { _, new in
            overflow = new
        }
        .overlay(alignment: .leading) { edgeFade(.leading).opacity(overflow.leading ? 1 : 0) }
        .overlay(alignment: .trailing) { edgeFade(.trailing).opacity(overflow.trailing ? 1 : 0) }
        .animation(.lpQuick, value: overflow)
        .animation(.lpQuick, value: laneWidth)
    }

    /// The card being dragged, lifted and following the pointer.
    @ViewBuilder
    fileprivate var floatingCard: some View {
        if let id = drag.cardID, let card = store.board.card(withID: id) {
            CardView(card: card, isDone: store.isDone(card))
                .frame(width: drag.cardSize.width)
                .rotationEffect(.degrees(reduceMotion ? 0 : 1.5))
                .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
                .offset(x: drag.location.x - drag.grabOffset.width, y: drag.location.y - drag.grabOffset.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// A soft fade where lists continue beyond the edge, so it is clear the board scrolls.
    fileprivate func edgeFade(_ edge: HorizontalEdge) -> some View {
        LinearGradient(colors: [Color.lpCanvas.opacity(0), Color.lpCanvas],
                       startPoint: edge == .trailing ? .leading : .trailing,
                       endPoint: edge == .trailing ? .trailing : .leading)
            .frame(width: 36)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Header

private struct BoardHeader: View {
    let store: BoardStore
    @Environment(AppModel.self) private var app
    @State private var title = ""
    @State private var showsIconPicker = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        let progress = store.progress
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    showsIconPicker = true
                } label: {
                    Group {
                        if let icon = store.icon {
                            Text(icon).font(.lp(size: 26))
                        } else {
                            Image(systemName: "rectangle.split.3x1")
                                .font(.lp(size: 17, weight: .medium))
                                .foregroundStyle(Color.lpInkSecondary)
                        }
                    }
                    .frame(width: 46, height: 46)
                    .background(Color.lpFillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Change icon")
                .accessibilityLabel("Board icon")
                .popover(isPresented: $showsIconPicker, arrowEdge: .bottom) {
                    EmojiPicker(current: store.icon) { choice in
                        store.setIcon(choice)
                        showsIconPicker = false
                    }
                }

                TextField("Untitled Board", text: $title)
                    .textFieldStyle(.plain)
                    .font(.lp(size: 28, weight: .bold))
                    .foregroundStyle(Color.lpInk)
                    .focused($isTitleFocused)
                    .onSubmit(commitTitle)
                    .onChange(of: isTitleFocused) { _, focused in if !focused { commitTitle() } }
            }

            HStack(spacing: 12) {
                Text("\(progress.done) of \(progress.total) done")
                    .font(.lp(size: 13, weight: .medium))
                    .foregroundStyle(Color.lpInkSecondary)
                    .monospacedDigit()
                LaneProgressBar(progress: progress)
                    .frame(width: 180, height: 6)
                Text("\(progress.percent)%")
                    .font(.lp(size: 13, weight: .semibold))
                    .foregroundStyle(Color.lpInk)
                    .monospacedDigit()
                if progress.overdue > 0 {
                    Label("\(progress.overdue) overdue", systemImage: "exclamationmark.circle.fill")
                        .font(.lp(size: 12.5, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
                if store.share != nil {
                    Label("Shared", systemImage: "person.2.fill")
                        .font(.lp(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .onAppear {
            title = store.title
            if store.focusTitleOnAppear {
                store.focusTitleOnAppear = false
                DispatchQueue.main.async { isTitleFocused = true }
            }
        }
        .onChange(of: store.path) { title = store.title }
    }

    private func commitTitle() {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, wanted != store.title else {
            title = store.title
            return
        }
        if !app.rename(store.path, to: wanted) { title = store.title }
    }
}

/// How the board's cards are spread across its lists, as one segmented bar. Segments are
/// separated by a 2pt gap of background rather than outlined.
struct LaneProgressBar: View {
    let progress: BoardProgress
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let filled = progress.perLane.enumerated().filter { $0.element.count > 0 }
            let available = proxy.size.width - gap * CGFloat(max(filled.count - 1, 0))
            HStack(spacing: gap) {
                if progress.total == 0 {
                    Capsule().fill(Color.lpFillSelected)
                } else {
                    ForEach(filled, id: \.offset) { index, lane in
                        Rectangle()
                            .fill(BoardPalette.lane(index, of: progress.perLane.count))
                            .frame(width: max(2, available * CGFloat(lane.count) / CGFloat(progress.total)))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Lists

private struct LaneView: View {
    let lane: BoardLane
    let index: Int
    let width: CGFloat
    let store: BoardStore
    let drag: BoardCardDrag
    let onOpen: (BoardCard) -> Void

    @Environment(\.undoManager) private var undoManager
    @State private var isAdding = false
    @State private var draft = ""
    @State private var isRenaming = false
    @State private var titleDraft = ""
    /// Text from another app is being dragged over this list.
    @State private var isDropTargeted = false
    @FocusState private var isDraftFocused: Bool
    @FocusState private var isTitleFocused: Bool

    private var color: Color { BoardPalette.lane(index, of: store.board.lanes.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(lane.cards) { card in
                CardView(card: card, isDone: card.isDone || lane.marksComplete,
                         isDropTarget: drag.target == BoardDropTarget(laneID: lane.id, beforeCardID: card.id))
                    .opacity(drag.cardID == card.id ? 0.35 : 1)
                    .reportsBoardFrame(CardFramesKey.self, id: card.id)
                    .gesture(cardDrag(card))
                    .onTapGesture { onOpen(card) }
                    // The keyboard can do everything the mouse can: open, move between lists, delete.
                    .onKeyPress(.return) {
                        onOpen(card)
                        return .handled
                    }
                    .onKeyPress(.space) {
                        onOpen(card)
                        return .handled
                    }
                    .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        store.shift(card.id, by: press.key == .leftArrow ? -1 : 1, undoManager: undoManager)
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        store.delete(card.id, undoManager: undoManager)
                        return .handled
                    }
                    .contextMenu { cardMenu(card) }
                    .accessibilityAction(named: "Move to Next List") { store.shift(card.id, by: 1, undoManager: undoManager) }
                    .accessibilityAction(named: "Move to Previous List") { store.shift(card.id, by: -1, undoManager: undoManager) }
            }

            // A dragged card would go at the end of this list.
            if drag.target == BoardDropTarget(laneID: lane.id, beforeCardID: nil) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .padding(.horizontal, 2)
                    .accessibilityHidden(true)
            }

            if lane.cards.isEmpty, !isAdding {
                emptyDropArea
            }
            addCard
        }
        .padding(10)
        .frame(width: width, alignment: .top)
        .background(Color.lpFillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.7 : 0), lineWidth: 2)
        }
        .reportsBoardFrame(LaneFramesKey.self, id: lane.id)
        // Text dragged in from another app becomes new cards.
        .dropDestination(for: String.self) { items, _ in
            for text in items { store.addCard(text, toLane: lane.id, undoManager: undoManager) }
            return !items.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    /// Picking up a card and dropping it anywhere on the board.
    private func cardDrag(_ card: BoardCard) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(BoardCardDrag.space))
            .onChanged { value in
                drag.update(card, start: value.startLocation, location: value.location, board: store.board)
            }
            .onEnded { _ in
                guard let (cardID, target) = drag.finish() else { return }
                withAnimation(.lpQuick) {
                    store.move([cardID], toLane: target.laneID, before: target.beforeCardID, undoManager: undoManager)
                }
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            if isRenaming {
                TextField("List name", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.lp(size: 13, weight: .semibold))
                    .focused($isTitleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: isTitleFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(lane.title)
                    .font(.lp(size: 13, weight: .semibold))
                    .foregroundStyle(Color.lpInk)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { startRename() }
                if lane.marksComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.lp(size: 11))
                        .foregroundStyle(BoardPalette.complete)
                        .help("Cards in this list count as done")
                        .accessibilityLabel("Cards here count as done")
                }
            }
            Text("\(lane.cards.count)")
                .font(.lp(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.lpInkSecondary)
            Spacer(minLength: 0)
            Menu {
                Button("Add Card", systemImage: "plus") { startAdding() }
                Button("Rename", systemImage: "pencil") { startRename() }
                Toggle("Cards Here Count as Done", isOn: Binding(
                    get: { lane.marksComplete },
                    set: { store.setMarksComplete(lane.id, $0, undoManager: undoManager) }
                ))
                Divider()
                Button("Move Left", systemImage: "arrow.left") { store.moveLane(lane.id, by: -1, undoManager: undoManager) }
                    .disabled(index == 0)
                Button("Move Right", systemImage: "arrow.right") { store.moveLane(lane.id, by: 1, undoManager: undoManager) }
                    .disabled(index == store.board.lanes.count - 1)
                Divider()
                Button("Delete List", systemImage: "trash", role: .destructive) {
                    store.deleteLane(lane.id, undoManager: undoManager)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.lp(size: 11, weight: .semibold))
                    .foregroundStyle(Color.lpInkSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("List options")
            .accessibilityLabel("Options for \(lane.title)")
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
    }

    /// Somewhere to drop cards on an empty list. Text dragged in from elsewhere becomes a card.
    private var emptyDropArea: some View {
        Text("Drop cards here")
            .font(.lp(size: 12))
            .foregroundStyle(Color.lpInkTertiary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.lpInkFaint, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
    }

    @ViewBuilder
    private var addCard: some View {
        if isAdding {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Card title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.lp(size: 13.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.lpSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
                    .focused($isDraftFocused)
                    .onSubmit(commitAdd)
                    .onExitCommand(perform: cancelAdd)
                HStack(spacing: 8) {
                    Button("Add Card", action: commitAdd)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Cancel", action: cancelAdd)
                        .buttonStyle(.plain)
                        .font(.lp(size: 12))
                        .foregroundStyle(Color.lpInkSecondary)
                }
            }
        } else {
            Button(action: startAdding) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.lp(size: 11, weight: .semibold))
                    Text("Add a card").font(.lp(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.lpInkSecondary)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
        }
    }

    @ViewBuilder
    private func cardMenu(_ card: BoardCard) -> some View {
        Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { onOpen(card) }
        Menu("Move To") {
            ForEach(store.board.lanes) { other in
                Button(other.title) { store.move([card.id], toLane: other.id, before: nil, undoManager: undoManager) }
                    .disabled(other.id == lane.id)
            }
        }
        if !lane.marksComplete {
            Button(card.isDone ? "Mark as Not Done" : "Mark as Done", systemImage: card.isDone ? "circle" : "checkmark.circle") {
                store.setDone(card.id, !card.isDone, undoManager: undoManager)
            }
        }
        Divider()
        Button("Archive", systemImage: "archivebox") { store.archive(card.id, undoManager: undoManager) }
        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(card.id, undoManager: undoManager) }
    }

    private func startAdding() {
        isAdding = true
        isDraftFocused = true
    }

    private func commitAdd() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else {
            cancelAdd()
            return
        }
        withAnimation(.lpQuick) {
            _ = store.addCard(draft, toLane: lane.id, undoManager: undoManager)
        }
        draft = ""
        isDraftFocused = true
    }

    private func cancelAdd() {
        draft = ""
        isAdding = false
    }

    private func startRename() {
        titleDraft = lane.title
        isRenaming = true
        isTitleFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        store.renameLane(lane.id, to: titleDraft, undoManager: undoManager)
    }
}

// MARK: - Cards

private struct CardView: View {
    let card: BoardCard
    let isDone: Bool
    /// A dragged card would be placed just above this one.
    var isDropTarget = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.lp(size: 12.5))
                        .foregroundStyle(BoardPalette.complete)
                        .accessibilityLabel("Done")
                }
                Text(card.title.isEmpty ? "Untitled card" : card.title)
                    .font(.lp(size: 13.5))
                    .foregroundStyle(isDone ? Color.lpInkSecondary : Color.lpInk)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasDetails {
                details
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lpSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.lpHairline.opacity(isHovering ? 1.8 : 1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isHovering ? 0.09 : 0.035), radius: isHovering ? 6 : 1.5, x: 0, y: isHovering ? 3 : 1)
        .overlay {
            // A focus ring of its own, drawn just outside the card.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-2)
                .opacity(isFocused ? 1 : 0)
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 3)
                .offset(y: -6)
                .opacity(isDropTarget ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(.lpQuick, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the card. Use the actions, or Command and the arrow keys, to move it to another list.")
    }

    private var hasDetails: Bool {
        card.due != nil || !card.tags.isEmpty || !card.body.isEmpty
    }

    private var details: some View {
        FlowRow(spacing: 6) {
            if let due = card.due {
                DueChip(day: due, time: CardText.dueTime(in: card.text), isDone: isDone)
            }
            ForEach(card.tags, id: \.self) { tag in
                TagChip(tag: tag)
            }
            if let checklist = card.checklist {
                Label("\(checklist.done)/\(checklist.total)", systemImage: "checklist")
                    .font(.lp(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(checklist.done == checklist.total ? Color.lpGood : Color.lpInkSecondary)
                    .frame(height: 20)
            } else if !card.body.isEmpty {
                Image(systemName: "text.alignleft")
                    .font(.lp(size: 11))
                    .foregroundStyle(Color.lpInkSecondary)
                    .frame(height: 20)
                    .accessibilityLabel("Has notes")
            }
        }
    }
}

/// A due date, coloured by how soon it is. The words and the icon carry the meaning too, so
/// it never rests on colour alone.
struct DueChip: View {
    let day: Day
    var time: TimeOfDay? = nil
    let isDone: Bool

    var body: some View {
        let today = Day.today
        let (color, prefix, symbol): (Color, String, String) = {
            if isDone { return (Color.lpInkSecondary, "", "calendar") }
            if day < today { return (Color.lpCritical, "Overdue · ", "exclamationmark.circle") }
            if day == today { return (Color.lpAccentText, "", "calendar") }
            if day <= today.adding(days: 3) { return (Color.lpWarning, "", "clock") }
            return (Color.lpInkSecondary, "", "calendar")
        }()
        Label(prefix + day.relativeTitle + (time.map { " \($0.title)" } ?? ""), systemImage: symbol)
            .font(.lp(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(color.opacity(isDone ? 0.08 : 0.12), in: Capsule())
    }
}

/// A tag: a coloured dot for identity, the name in ink so it is always readable.
struct TagChip: View {
    let tag: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(BoardPalette.tag(tag))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(tag)
                .font(.lp(size: 11, weight: .medium))
                .foregroundStyle(Color.lpInkSecondary)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Color.lpFillSubtle, in: Capsule())
        .accessibilityLabel("Tag \(tag)")
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Adding a list

private struct AddLaneButton: View {
    let store: BoardStore
    @Environment(\.undoManager) private var undoManager
    @State private var isAdding = false
    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isAdding {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("List name", text: $title)
                        .textFieldStyle(.plain)
                        .font(.lp(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color.lpSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
                        .focused($isFocused)
                        .onSubmit(commit)
                        .onExitCommand { cancel() }
                    HStack(spacing: 8) {
                        Button("Add List", action: commit).buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel", action: cancel).buttonStyle(.plain).font(.lp(size: 12)).foregroundStyle(Color.lpInkSecondary)
                    }
                }
                .padding(10)
                .background(Color.lpFillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Button {
                    isAdding = true
                    isFocused = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.lp(size: 11, weight: .semibold))
                        Text("Add list").font(.lp(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.lpInkSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color.lpFillSubtle.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.lpHairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: BoardLayout.addListWidth)
    }

    private func commit() {
        store.addLane(title, undoManager: undoManager)
        cancel()
    }

    private func cancel() {
        title = ""
        isAdding = false
    }
}
