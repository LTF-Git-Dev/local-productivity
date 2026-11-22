//
//  SearchHit.swift
//  Local Productivity
//
//  A page that matched a search, and which of them ⌘K lists under "In pages". Plain Foundation,
//  so the rule is tested (Scripts/test.sh search).
//

import Foundation

nonisolated struct SearchHit: Identifiable, Hashable, Sendable {
    var path: String
    var title: String
    var icon: String?
    var snippet: String
    /// At least one of the words is in the page's name (the others may be only inside it).
    var isTitleMatch: Bool

    var id: String { path }

    /// The hits ⌘K lists under "In pages": every one not already listed under "Pages", in order.
    /// A page whose name holds only some of the words (the rest are inside it) isn't under
    /// "Pages", so it must stay here even though it's a title match — "launch budget" finds a page
    /// named "Launch Plan" that mentions the budget.
    static func inPages(_ hits: [SearchHit], listedAsPages: Set<String>) -> [SearchHit] {
        hits.filter { !listedAsPages.contains($0.path) }
    }
}
