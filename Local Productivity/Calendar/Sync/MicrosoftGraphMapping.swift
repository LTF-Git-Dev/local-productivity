//
//  MicrosoftGraphMapping.swift
//  LP
//
//  Translates between LP's calendar values and Microsoft Graph, which serves Outlook,
//  Outlook.com, Hotmail and Microsoft 365 calendars. No networking happens here.
//

import Foundation

nonisolated enum MicrosoftGraphMapping {

    static let apiBase = URL(string: "https://graph.microsoft.com/v1.0")!

    /// The redirect scheme Microsoft's portal generates for a Mac app with this bundle ID
    /// ("iOS / macOS" platform): `msauth.<bundle id>://auth`.
    static func redirectScheme(bundleID: String) -> String {
        "msauth." + bundleID
    }

    static func configuration(clientID raw: String, bundleID: String) -> OAuthConfiguration? {
        let clientID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Application (client) IDs are GUIDs.
        guard UUID(uuidString: clientID) != nil else { return nil }
        let scheme = redirectScheme(bundleID: bundleID)
        return OAuthConfiguration(
            authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            clientID: clientID,
            redirectURI: scheme + "://auth",
            callbackScheme: scheme,
            scopes: ["offline_access", "https://graph.microsoft.com/Calendars.ReadWrite", "https://graph.microsoft.com/User.Read"],
            extraAuthorizeParameters: ["prompt": "select_account", "response_mode": "query"],
            sendsScopeOnRefresh: true
        )
    }

    // MARK: URLs

    private static func pathComponent(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: apiBase.absoluteString + path)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    static func meURL() -> URL {
        url("/me", [URLQueryItem(name: "$select", value: "mail,userPrincipalName,displayName")])
    }

    static func calendarsURL() -> URL {
        url("/me/calendars", [URLQueryItem(name: "$top", value: "100")])
    }

    static let eventFields = "id,subject,body,location,start,end,isAllDay,type,seriesMasterId,webLink,changeKey"

    /// Occurrences in a time window, with repeating events expanded.
    static func calendarViewURL(calendarID: String, interval: DateInterval) -> URL {
        url("/me/calendars/\(pathComponent(calendarID))/calendarView", [
            URLQueryItem(name: "startDateTime", value: CalendarDates.rfc3339(interval.start)),
            URLQueryItem(name: "endDateTime", value: CalendarDates.rfc3339(interval.end)),
            URLQueryItem(name: "$top", value: "500"),
            URLQueryItem(name: "$select", value: eventFields)
        ])
    }

    static func eventURL(eventID: String) -> URL {
        url("/me/events/\(pathComponent(eventID))", [URLQueryItem(name: "$select", value: eventFields)])
    }

    static func createURL(calendarID: String) -> URL {
        url("/me/calendars/\(pathComponent(calendarID))/events")
    }

    /// Times come back in UTC and descriptions as plain text.
    static func applyPreferences(to request: inout URLRequest) {
        request.addValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        request.addValue("outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
    }

    // MARK: Reading

    struct Page<Item> {
        var items: [Item]
        var nextLink: URL?
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarSyncError.invalidResponse
        }
        return json
    }

    static func accountName(from data: Data) throws -> String {
        let json = try object(data)
        let name = (json["mail"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? json["userPrincipalName"] as? String
        guard let name, !name.isEmpty else { throw CalendarSyncError.invalidResponse }
        return name
    }

    /// Outlook's named calendar colours.
    static let namedColors: [String: String] = [
        "lightBlue": "#5AA8E8", "lightGreen": "#5DBE7E", "lightOrange": "#F2A35A", "lightGray": "#9AA0A6",
        "lightYellow": "#E8C547", "lightTeal": "#4FBDBA", "lightPink": "#E87AA4", "lightBrown": "#B08B6E",
        "lightRed": "#E86A6A", "maxColor": "#7A7AE0", "auto": "#2F7CD6"
    ]

    static func calendars(from data: Data, accountID: String, accountName: String) throws -> Page<SyncCalendar> {
        let json = try object(data)
        let items = (json["value"] as? [[String: Any]] ?? []).compactMap { item -> SyncCalendar? in
            guard let id = item["id"] as? String else { return nil }
            let hex = (item["hexColor"] as? String).flatMap { $0.hasPrefix("#") && $0.count == 7 ? $0 : nil }
            return SyncCalendar(
                accountID: accountID,
                remoteID: id,
                title: item["name"] as? String ?? "Calendar",
                colorHex: hex ?? namedColors[item["color"] as? String ?? "auto"] ?? "#2F7CD6",
                isWritable: item["canEdit"] as? Bool ?? false,
                sourceTitle: accountName
            )
        }
        return Page(items: items, nextLink: (json["@odata.nextLink"] as? String).flatMap(URL.init(string:)))
    }

    static func events(from data: Data, calendar: SyncCalendar) throws -> Page<SyncEvent> {
        let json = try object(data)
        let items = (json["value"] as? [[String: Any]] ?? []).compactMap { event(from: $0, calendar: calendar) }
        return Page(items: items, nextLink: (json["@odata.nextLink"] as? String).flatMap(URL.init(string:)))
    }

    static func event(from data: Data, calendar: SyncCalendar) throws -> SyncEvent {
        guard let event = event(from: try object(data), calendar: calendar) else { throw CalendarSyncError.invalidResponse }
        return event
    }

    static func event(from item: [String: Any], calendar: SyncCalendar) -> SyncEvent? {
        guard let id = item["id"] as? String,
              let startObject = item["start"] as? [String: Any], let endObject = item["end"] as? [String: Any] else { return nil }
        let isAllDay = item["isAllDay"] as? Bool ?? false
        guard let start = time(startObject, allDay: isAllDay), let end = time(endObject, allDay: isAllDay) else { return nil }
        let type = item["type"] as? String ?? "singleInstance"
        let isOccurrence = type == "occurrence" || type == "exception"
        let body = (item["body"] as? [String: Any])?["content"] as? String ?? ""
        return SyncEvent(
            accountID: calendar.accountID,
            calendarID: calendar.id,
            remoteID: id,
            seriesID: isOccurrence ? item["seriesMasterId"] as? String : nil,
            title: (item["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(No title)",
            start: start,
            end: max(end, start),
            isAllDay: isAllDay,
            location: ((item["location"] as? [String: Any])?["displayName"] as? String) ?? "",
            notes: body.trimmingCharacters(in: .whitespacesAndNewlines),
            url: (item["webLink"] as? String).flatMap(URL.init(string:)),
            version: item["changeKey"] as? String
        )
    }

    /// A Graph `dateTimeTimeZone`. All-day events are read as floating dates.
    static func time(_ object: [String: Any], allDay: Bool) -> Date? {
        guard let text = object["dateTime"] as? String, text.count >= 19 else { return nil }
        if allDay { return CalendarDates.localDate(fromDayString: String(text.prefix(10))) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: object["timeZone"] as? String ?? "UTC") ?? TimeZone(identifier: "UTC")
        return formatter.date(from: String(text.prefix(19)))
    }

    // MARK: Writing

    static func timeObject(_ date: Date, allDay: Bool, timeZone: TimeZone) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if allDay {
            // All-day events run midnight to midnight in the person's own time zone.
            formatter.timeZone = timeZone
            return ["dateTime": formatter.string(from: CalendarDates.startOfDay(date)), "timeZone": timeZone.identifier]
        }
        formatter.timeZone = TimeZone(identifier: "UTC")
        return ["dateTime": formatter.string(from: date), "timeZone": "UTC"]
    }

    static func body(for draft: EventDraft, timeZone: TimeZone = .current) -> Data {
        let fields: [String: Any] = [
            "subject": draft.title,
            "body": ["contentType": "text", "content": draft.notes],
            "location": ["displayName": draft.location],
            "start": timeObject(draft.start, allDay: draft.isAllDay, timeZone: timeZone),
            "end": timeObject(draft.end, allDay: draft.isAllDay, timeZone: timeZone),
            "isAllDay": draft.isAllDay
        ]
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }
}
