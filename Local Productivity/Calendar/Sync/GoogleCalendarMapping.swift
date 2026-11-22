//
//  GoogleCalendarMapping.swift
//  LP
//
//  Translates between LP's calendar values and the Google Calendar API (v3): sign-in
//  configuration, request URLs, response parsing and request bodies. No networking
//  happens here, so all of it can be tested with recorded responses.
//

import Foundation

nonisolated enum GoogleCalendarMapping {

    static let apiBase = URL(string: "https://www.googleapis.com/calendar/v3")!

    /// The only Google Drive permission LP ever asks for, and only for sharing boards: the files LP
    /// itself creates — nothing else in the Drive.
    static let driveFileScope = "https://www.googleapis.com/auth/drive.file"

    /// Sign-in settings for a Google "iOS" OAuth client, which works for Mac apps and needs no
    /// secret. Its redirect uses the client ID reversed into a URL scheme. `includeDrive` adds the
    /// Drive permission (for sharing boards); `loginHint` picks the account on Google's page.
    static func configuration(clientID raw: String, includeDrive: Bool = false, loginHint: String? = nil) -> OAuthConfiguration? {
        let clientID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix), clientID.count > suffix.count, !clientID.contains(" ") else { return nil }
        let scheme = "com.googleusercontent.apps." + clientID.dropLast(suffix.count)
        return OAuthConfiguration(
            authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            clientID: clientID,
            redirectURI: scheme + ":/oauth2redirect",
            callbackScheme: scheme,
            // Only what LP needs: the list of calendars (read only) and their events — not the
            // permission to change calendars themselves or who they are shared with.
            scopes: ["https://www.googleapis.com/auth/calendar.calendarlist.readonly",
                     "https://www.googleapis.com/auth/calendar.events"] + (includeDrive ? [driveFileScope] : []),
            // Ask for a refresh token so the account stays connected; keep what was granted before
            // (connecting again doesn't drop Drive), and pick the right account when asked to.
            extraAuthorizeParameters: ["access_type": "offline", "prompt": "consent", "include_granted_scopes": "true"]
                .merging(loginHint.map { ["login_hint": $0] } ?? [:]) { first, _ in first },
            revocationURL: revocationURL
        )
    }

    /// Where Google ends an app's access (it needs only the token, not the client ID).
    static let revocationURL = URL(string: "https://oauth2.googleapis.com/revoke")!

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

    /// The fields LP reads, so Google sends nothing more (no attendees, organisers or the like).
    static let calendarFields = "items(id,summary,summaryOverride,backgroundColor,accessRole,deleted),nextPageToken"
    static let eventFields = "id,status,summary,description,location,start,end,recurringEventId,htmlLink,etag"
    static let eventListFields = "items(\(eventFields)),nextPageToken"

    static func calendarListURL(pageToken: String? = nil) -> URL {
        var query = [URLQueryItem(name: "maxResults", value: "250"), URLQueryItem(name: "fields", value: calendarFields)]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return url("/users/me/calendarList", query)
    }

    /// The primary calendar's entry in the calendar list, whose identifier is the account's email
    /// address (readable with the calendar-list permission alone).
    static func primaryCalendarURL() -> URL {
        url("/users/me/calendarList/primary", [URLQueryItem(name: "fields", value: "id")])
    }

    static func eventsURL(calendarID: String, interval: DateInterval, pageToken: String? = nil) -> URL {
        var query = [
            URLQueryItem(name: "timeMin", value: CalendarDates.rfc3339(interval.start)),
            URLQueryItem(name: "timeMax", value: CalendarDates.rfc3339(interval.end)),
            // Expand repeating events into their occurrences.
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "maxResults", value: "2500"),
            URLQueryItem(name: "fields", value: eventListFields)
        ]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return url("/calendars/\(pathComponent(calendarID))/events", query)
    }

    /// One event, for reading or changing it: Google sends back only the fields LP reads.
    static func eventURL(calendarID: String, eventID: String) -> URL {
        url("/calendars/\(pathComponent(calendarID))/events/\(pathComponent(eventID))", [URLQueryItem(name: "fields", value: eventFields)])
    }

    /// One event, for deleting it (nothing comes back).
    static func deleteURL(calendarID: String, eventID: String) -> URL {
        url("/calendars/\(pathComponent(calendarID))/events/\(pathComponent(eventID))")
    }

    static func insertURL(calendarID: String) -> URL {
        url("/calendars/\(pathComponent(calendarID))/events", [URLQueryItem(name: "fields", value: eventFields)])
    }

    // MARK: Reading

    struct Page<Item> {
        var items: [Item]
        var nextPageToken: String?
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarSyncError.invalidResponse
        }
        return json
    }

    static func primaryCalendarID(from data: Data) throws -> String {
        guard let id = try object(data)["id"] as? String, !id.isEmpty else { throw CalendarSyncError.invalidResponse }
        return id
    }

    static func calendars(from data: Data, accountID: String, accountName: String) throws -> Page<SyncCalendar> {
        let json = try object(data)
        let items = (json["items"] as? [[String: Any]] ?? []).compactMap { item -> SyncCalendar? in
            guard let id = item["id"] as? String else { return nil }
            if item["deleted"] as? Bool == true { return nil }
            let role = item["accessRole"] as? String ?? "reader"
            return SyncCalendar(
                accountID: accountID,
                remoteID: id,
                title: item["summaryOverride"] as? String ?? item["summary"] as? String ?? id,
                colorHex: item["backgroundColor"] as? String ?? "#4285F4",
                isWritable: role == "owner" || role == "writer",
                sourceTitle: accountName
            )
        }
        return Page(items: items, nextPageToken: json["nextPageToken"] as? String)
    }

    static func events(from data: Data, calendar: SyncCalendar) throws -> Page<SyncEvent> {
        let json = try object(data)
        let items = (json["items"] as? [[String: Any]] ?? []).compactMap { event(from: $0, calendar: calendar) }
        return Page(items: items, nextPageToken: json["nextPageToken"] as? String)
    }

    static func event(from data: Data, calendar: SyncCalendar) throws -> SyncEvent {
        guard let event = event(from: try object(data), calendar: calendar) else { throw CalendarSyncError.invalidResponse }
        return event
    }

    static func event(from item: [String: Any], calendar: SyncCalendar) -> SyncEvent? {
        guard let id = item["id"] as? String, item["status"] as? String != "cancelled",
              let startObject = item["start"] as? [String: Any], let endObject = item["end"] as? [String: Any],
              let (start, startIsDay) = time(startObject), let (end, _) = time(endObject) else { return nil }
        return SyncEvent(
            accountID: calendar.accountID,
            calendarID: calendar.id,
            remoteID: id,
            seriesID: item["recurringEventId"] as? String,
            title: (item["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(No title)",
            start: start,
            end: max(end, start),
            isAllDay: startIsDay,
            location: item["location"] as? String ?? "",
            notes: item["description"] as? String ?? "",
            url: (item["htmlLink"] as? String).flatMap(URL.init(string:)),
            version: item["etag"] as? String
        )
    }

    /// An event time: `{"date": "2026-11-17"}` for all-day events, otherwise `{"dateTime": …}`.
    static func time(_ object: [String: Any]) -> (Date, Bool)? {
        if let date = object["date"] as? String, let day = CalendarDates.localDate(fromDayString: date) {
            return (day, true)
        }
        if let text = object["dateTime"] as? String, let instant = CalendarDates.parseRFC3339(text) {
            return (instant, false)
        }
        return nil
    }

    // MARK: Writing

    static func timeObject(_ date: Date, allDay: Bool, timeZone: TimeZone) -> [String: Any] {
        // A patch merges objects, so the field not in use is cleared explicitly.
        if allDay {
            return ["date": CalendarDates.dayString(date), "dateTime": NSNull(), "timeZone": NSNull()]
        }
        return ["dateTime": CalendarDates.rfc3339(date), "timeZone": timeZone.identifier, "date": NSNull()]
    }

    static func body(for draft: EventDraft, timeZone: TimeZone = .current) -> Data {
        let fields: [String: Any] = [
            "summary": draft.title,
            "description": draft.notes,
            "location": draft.location,
            "start": timeObject(draft.start, allDay: draft.isAllDay, timeZone: timeZone),
            "end": timeObject(draft.end, allDay: draft.isAllDay, timeZone: timeZone)
        ]
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }
}
