//
//  WidgetSnapshot.swift
//  LP
//
//  What the widgets show. The app writes it to the App Group container it shares with the
//  widget extension; the extension only reads it. Compiled into both targets, so it uses
//  Foundation types only.
//

import Foundation
import Security

nonisolated struct WidgetSnapshot: Codable, Hashable, Sendable {

    /// An open task or card with a due date.
    struct Item: Codable, Hashable, Sendable {
        var title: String
        /// The page or board it is on.
        var source: String
        /// Workspace-relative path, for opening it.
        var path: String
        /// The day it is due, "2026-11-20".
        var due: String
        /// Minutes after midnight, when it names a time.
        var time: Int?
        var isCard: Bool
    }

    struct Event: Codable, Hashable, Sendable {
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var location: String
        /// The calendar's colour, "#RRGGBB".
        var color: String?
    }

    struct Board: Codable, Hashable, Sendable, Identifiable {
        var path: String
        var title: String
        var icon: String?
        var total: Int
        var done: Int
        var lists: [List]
        /// Due days of the cards still open, "2026-11-20".
        var openDue: [String]
        var modified: Date

        var id: String { path }
        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
        var percent: Int { Int((fraction * 100).rounded()) }

        func overdue(on day: String) -> Int { openDue.filter { $0 < day }.count }
    }

    struct List: Codable, Hashable, Sendable {
        var title: String
        var count: Int
        var marksComplete: Bool
    }

    var generated: Date
    var workspace: String
    var items: [Item]
    var events: [Event]
    var boards: [Board]

    // MARK: Reading it for a day

    func due(on day: String) -> [Item] {
        items.filter { $0.due == day }.sorted { ($0.time ?? 24 * 60, $0.title) < ($1.time ?? 24 * 60, $1.title) }
    }

    func overdue(on day: String) -> [Item] {
        items.filter { $0.due < day }.sorted { ($0.due, $0.title) < ($1.due, $1.title) }
    }

    /// Events still to come or happening at `date`, on the same day, all-day ones first.
    func events(on date: Date, calendar: Calendar = .current) -> [Event] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return events
            .filter { $0.start < end && $0.end > start && ($0.isAllDay || $0.end > date) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
    }

    /// "2026-11-20" for `date` in the current calendar.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

// MARK: - Storage

/// Where the snapshot lives: a file in the App Group container shared by LP and its widgets.
nonisolated enum WidgetStore {

    static let fileName = "widget-snapshot.json"

    /// "<Team ID>.LTF.Local-Productivity", matching the App Group entitlement. Nil when LP is
    /// signed without a team (ad hoc): macOS then asks before any access to the group
    /// container, which a widget cannot do, so LP leaves it alone and widgets show how to
    /// set them up instead.
    static let groupIdentifier: String? = teamIdentifier.map { "\($0).LTF.Local-Productivity" }

    /// The team the running code is signed by, from its own signature.
    static let teamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }()

    static var isAvailable: Bool { groupIdentifier != nil }

    static var fileURL: URL? {
        guard let groupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else { return nil }
        return container.appendingPathComponent(fileName)
    }

    static func load(from url: URL? = fileURL) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func encode(_ snapshot: WidgetSnapshot) -> Data? {
        try? encoder.encode(snapshot)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Links

/// Links that open LP at a page, a day or Home. They only ever navigate; nothing reached
/// through them changes a file.
nonisolated enum LPLink {

    static let scheme = "localproductivity"

    static var home: URL { URL(string: "\(scheme)://home")! }

    static func calendar(day: String) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "calendar"
        parts.queryItems = [URLQueryItem(name: "day", value: day)]
        return parts.url ?? home
    }

    static func open(_ path: String) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "path", value: path)]
        return parts.url ?? home
    }

    enum Destination: Equatable {
        case home
        case boards
        case calendar(day: String)
        case page(path: String)
    }

    static var boards: URL { URL(string: "\(scheme)://boards")! }

    static func destination(of url: URL) -> Destination? {
        guard url.scheme?.lowercased() == scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let value = { (name: String) in parts.queryItems?.first { $0.name == name }?.value }
        switch parts.host?.lowercased() {
        case "home": return .home
        case "boards": return .boards
        case "calendar": return value("day").map { .calendar(day: $0) } ?? .home
        case "open": return value("path").map { .page(path: $0) }
        default: return nil
        }
    }
}
