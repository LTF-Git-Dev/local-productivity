//
//  BoardLayout.swift
//  LP
//
//  Pure rules the board view follows, kept apart from SwiftUI so they can be tested: how wide
//  lists are for a given window, and where a dragged card lands.
//

import CoreGraphics
import Foundation

/// How wide a board's lists are: as wide as the window allows, within comfortable limits.
/// Wide windows fill with wider lists; narrow ones keep the minimum and scroll sideways.
nonisolated enum BoardLayout {
    static let margin: CGFloat = 28
    static let spacing: CGFloat = 14
    static let minimumLane: CGFloat = 260
    static let maximumLane: CGFloat = 340
    static let addListWidth: CGFloat = 220
    /// Below this width the progress panel floats over the board instead of sitting beside it.
    static let sideBySideWidth: CGFloat = 960
    static let panelWidth: CGFloat = 316

    static func laneWidth(available: CGFloat, lanes: Int) -> CGFloat {
        guard lanes > 0 else { return maximumLane }
        let usable = available - margin * 2 - addListWidth - spacing * CGFloat(lanes)
        return min(maximumLane, max(minimumLane, (usable / CGFloat(lanes)).rounded(.down)))
    }
}

/// Where a dragged card would land: which list, and before which card (nil = at the end).
nonisolated struct BoardDropTarget: Equatable, Sendable {
    var laneID: String
    var beforeCardID: String?

    struct Lane {
        var id: String
        var frame: CGRect
        /// The list's cards in order, with their frames.
        var cards: [(id: String, frame: CGRect)]
    }

    /// The target for a pointer at `point`, all in the same coordinate space. The list under the
    /// pointer is used, or the nearest one when the pointer is between lists; within it, the card
    /// goes before the first card whose middle is below the pointer. The dragged card itself is
    /// ignored, so dropping it where it is changes nothing.
    static func find(at point: CGPoint, in lanes: [Lane], dragging cardID: String) -> BoardDropTarget? {
        guard !lanes.isEmpty else { return nil }
        func distance(_ frame: CGRect) -> CGFloat {
            point.x < frame.minX ? frame.minX - point.x : (point.x > frame.maxX ? point.x - frame.maxX : 0)
        }
        guard let lane = lanes.min(by: { distance($0.frame) < distance($1.frame) }) else { return nil }
        let before = lane.cards.first { $0.id != cardID && $0.frame.midY > point.y }?.id
        return BoardDropTarget(laneID: lane.id, beforeCardID: before)
    }
}

