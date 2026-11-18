//
//  Compatibility.swift
//  LP
//
//  LP runs on macOS 15 (Sequoia), 26 (Tahoe) and 27. These helpers use the newer system looks
//  where they exist and leave the view unchanged on earlier versions, so call sites stay simple.
//  Only styling may differ between versions here — never behaviour.
//

import SwiftUI

extension View {
    /// Content fades softly under the toolbar as it scrolls (macOS 26 and later).
    @ViewBuilder
    func lpSoftScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

extension ToolbarContent {
    /// Removes the shared glass background behind a toolbar item (macOS 26 and later). Earlier
    /// versions draw no such background, so there is nothing to remove.
    @ToolbarContentBuilder
    func lpWithoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Pushes the toolbar items after it to the trailing edge, where macOS 26 groups them. Earlier
/// versions already place primary actions at the trailing edge.
struct LPFlexibleToolbarSpace: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        }
    }
}
