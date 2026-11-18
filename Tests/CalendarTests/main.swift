//
//  Calendar sync tests.
//
//  Run with `Scripts/test.sh`. They check that LP reads Google and Microsoft calendar
//  data correctly and writes requests those services accept, using recorded-style
//  responses — so they need no network and no accounts.
//

import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("✗ line \(line): \(message())")
    }
}

func json(_ text: String) -> Data { Data(text.utf8) }

func object(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

let calendar = Calendar.current
func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

// MARK: - PKCE and OAuth

do {
    let verifier = "LP-test-verifier-0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGH"
    check(PKCE.challenge(for: verifier) == "LjwD1pvnotHHw11G3JzWjiDDSTeMJ_NtaxM2APJ9ZWc", "S256 challenge matches an independent computation")
    let made = PKCE.makeVerifier()
    check(made.count == 64, "verifier length")
    check(made.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }, "verifier characters")
    check(PKCE.makeVerifier() != made, "verifiers are random")
}

do {
    let config = GoogleCalendarMapping.configuration(clientID: " 1234-abc.apps.googleusercontent.com ")
    check(config?.clientID == "1234-abc.apps.googleusercontent.com", "client ID is trimmed")
    check(config?.callbackScheme == "com.googleusercontent.apps.1234-abc", "Google callback scheme is the reversed client ID")
    check(config?.redirectURI == "com.googleusercontent.apps.1234-abc:/oauth2redirect", "Google redirect URI")
    check(GoogleCalendarMapping.configuration(clientID: "not a client id") == nil, "invalid Google client ID is rejected")

    if let config, let url = OAuthRequests.authorizeURL(config, state: "s1", challenge: "c1") {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        check(value("code_challenge_method") == "S256", "PKCE method")
        check(value("code_challenge") == "c1" && value("state") == "s1", "challenge and state are sent")
        check(value("access_type") == "offline", "Google asks for a refresh token")
        check(value("response_type") == "code", "authorization code flow")
    } else {
        check(false, "authorize URL")
    }
}

do {
    let config = MicrosoftGraphMapping.configuration(clientID: "8a1c2f3e-1111-2222-3333-444455556666", bundleID: "LTF.Local-Productivity")
    check(config?.redirectURI == "msauth.LTF.Local-Productivity://auth", "Microsoft redirect URI follows the portal's macOS format")
    check(config?.scopes.contains("offline_access") == true, "Microsoft asks for offline access")
    check(MicrosoftGraphMapping.configuration(clientID: "abc", bundleID: "x") == nil, "invalid Microsoft client ID is rejected")
}

do {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fresh = try OAuthRequests.tokens(from: json(#"{"access_token":"A","expires_in":3600,"refresh_token":"R"}"#), previousRefreshToken: nil, now: now)
    check(fresh.accessToken == "A" && fresh.refreshToken == "R", "token response")
    check(fresh.expiresAt == now.addingTimeInterval(3600), "expiry")
    let refreshed = try OAuthRequests.tokens(from: json(#"{"access_token":"B","expires_in":60}"#), previousRefreshToken: "R", now: now)
    check(refreshed.refreshToken == "R", "a refresh without a new refresh token keeps the old one")
    check(!refreshed.isFresh(at: now), "a token about to expire is not fresh")
    do {
        _ = try OAuthRequests.tokens(from: json(#"{"error":"invalid_grant"}"#), previousRefreshToken: "R")
        check(false, "invalid_grant should throw")
    } catch {
        check(error as? CalendarSyncError == .signInRequired, "invalid_grant means signing in again")
    }

    let callback = URL(string: "com.googleusercontent.apps.1:/oauth2redirect?code=XYZ&state=abc")!
    check((try? OAuthRequests.code(from: callback, expectedState: "abc")) == "XYZ", "code is read from the redirect")
    check((try? OAuthRequests.code(from: callback, expectedState: "other")) == nil, "a state mismatch is refused")
    let denied = URL(string: "msauth.x://auth?error=access_denied&state=abc")!
    do {
        _ = try OAuthRequests.code(from: denied, expectedState: "abc")
        check(false, "access_denied should throw")
    } catch {
        check(error as? CalendarSyncError == .cancelled, "declining consent counts as cancelling")
    }
} catch {
    check(false, "token tests threw \(error)")
}

// MARK: - Google Calendar

let googleCalendar = SyncCalendar(accountID: "google:me@example.com", remoteID: "me@example.com", title: "Me",
                                  colorHex: "#4285F4", isWritable: true, sourceTitle: "me@example.com")

do {
    let page = try GoogleCalendarMapping.calendars(from: json("""
    {"items":[
      {"id":"me@example.com","summary":"Me","backgroundColor":"#9fe1e7","accessRole":"owner","primary":true},
      {"id":"en.usa#holiday@group.v.calendar.google.com","summary":"Holidays","backgroundColor":"#16a765","accessRole":"reader"},
      {"id":"team@group.calendar.google.com","summary":"Team","summaryOverride":"Our team","accessRole":"writer"}
    ],"nextPageToken":"p2"}
    """), accountID: "google:me@example.com", accountName: "me@example.com")
    check(page.items.count == 3 && page.nextPageToken == "p2", "calendar list page")
    check(page.items[0].isWritable && page.items[0].colorHex == "#9fe1e7", "owner calendar is writable and keeps its colour")
    check(!page.items[1].isWritable, "reader calendar is read-only")
    check(page.items[2].title == "Our team" && page.items[2].isWritable, "summary override and writer access")
    check(page.items[0].id == "google:me@example.com|me@example.com", "calendar identity is scoped to the account")

    let url = GoogleCalendarMapping.eventsURL(calendarID: page.items[1].remoteID, interval: DateInterval(start: Date(), duration: 86_400))
    check(url.absoluteString.contains("en.usa%23holiday@group.v.calendar.google.com/events"), "calendar IDs are escaped in paths: \(url.absoluteString)")
    check(url.absoluteString.contains("singleEvents=true"), "repeating events are expanded")
} catch {
    check(false, "Google calendars threw \(error)")
}

do {
    let page = try GoogleCalendarMapping.events(from: json("""
    {"items":[
      {"id":"e1","status":"confirmed","summary":"Standup","etag":"\\"111\\"","htmlLink":"https://calendar.google.com/e1",
       "location":"Room 1","description":"Daily",
       "start":{"dateTime":"2026-11-17T09:00:00-08:00","timeZone":"America/Los_Angeles"},
       "end":{"dateTime":"2026-11-17T09:30:00-08:00"},"recurringEventId":"series1"},
      {"id":"e2","status":"confirmed","summary":"","start":{"date":"2026-11-20"},"end":{"date":"2026-11-23"}},
      {"id":"e3","status":"cancelled","start":{"date":"2026-11-20"},"end":{"date":"2026-11-21"}}
    ]}
    """), calendar: googleCalendar)
    check(page.items.count == 2, "cancelled events are skipped")
    let standup = page.items[0]
    check(standup.start == CalendarDates.parseRFC3339("2026-11-17T17:00:00Z"), "offsets become absolute times")
    check(standup.end.timeIntervalSince(standup.start) == 1800, "duration")
    check(!standup.isAllDay && standup.seriesID == "series1" && standup.isRecurring, "occurrence of a repeating event")
    check(standup.version == "\"111\"" && standup.location == "Room 1" && standup.notes == "Daily", "etag, location, notes")
    let trip = page.items[1]
    check(trip.isAllDay && trip.title == "(No title)", "all-day event without a title")
    check(trip.start == local(2026, 11, 20) && trip.end == local(2026, 11, 23), "all-day dates float at local midnight")
    check(trip.days().map(\.iso) == ["2026-11-20", "2026-11-21", "2026-11-22"], "an all-day event covers its days, end exclusive")
} catch {
    check(false, "Google events threw \(error)")
}

do {
    let timed = EventDraft(title: "Lunch", start: CalendarDates.parseRFC3339("2026-11-18T12:00:00Z")!,
                           end: CalendarDates.parseRFC3339("2026-11-18T13:00:00Z")!, isAllDay: false, location: "Café")
    let body = object(GoogleCalendarMapping.body(for: timed, timeZone: TimeZone(identifier: "Europe/Paris")!))
    let start = body["start"] as? [String: Any]
    check(body["summary"] as? String == "Lunch" && body["location"] as? String == "Café", "Google body fields")
    check((start?["dateTime"] as? String).flatMap(CalendarDates.parseRFC3339) == timed.start, "Google start instant")
    check(start?["timeZone"] as? String == "Europe/Paris", "Google time zone")
    check(start?["date"] is NSNull, "switching to a timed event clears the all-day date")

    let allDay = EventDraft(title: "Trip", start: local(2026, 11, 20), end: local(2026, 11, 23), isAllDay: true)
    let dayBody = object(GoogleCalendarMapping.body(for: allDay))
    check((dayBody["start"] as? [String: Any])?["date"] as? String == "2026-11-20", "Google all-day start")
    check((dayBody["end"] as? [String: Any])?["date"] as? String == "2026-11-23", "Google all-day end is exclusive")
    check((dayBody["start"] as? [String: Any])?["dateTime"] is NSNull, "switching to all-day clears the time")
}

// MARK: - Microsoft Graph

let outlookCalendar = SyncCalendar(accountID: "microsoft:me@outlook.com", remoteID: "AAMk", title: "Calendar",
                                   colorHex: "#2F7CD6", isWritable: true, sourceTitle: "me@outlook.com")

do {
    check(try MicrosoftGraphMapping.accountName(from: json(#"{"mail":null,"userPrincipalName":"me@outlook.com"}"#)) == "me@outlook.com",
          "account name falls back to the user principal name")
    let page = try MicrosoftGraphMapping.calendars(from: json("""
    {"value":[
      {"id":"AAMk","name":"Calendar","color":"auto","hexColor":"","canEdit":true},
      {"id":"BBMk","name":"Birthdays","color":"lightGreen","hexColor":"","canEdit":false},
      {"id":"CCMk","name":"Work","color":"auto","hexColor":"#ff8c00","canEdit":true}
    ],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendars?$skip=3"}
    """), accountID: "microsoft:me@outlook.com", accountName: "me@outlook.com")
    check(page.items.count == 3 && page.nextLink != nil, "calendars page")
    check(page.items[1].colorHex == "#5DBE7E" && !page.items[1].isWritable, "named colour and read-only calendar")
    check(page.items[2].colorHex == "#ff8c00", "explicit hex colour wins")
} catch {
    check(false, "Graph calendars threw \(error)")
}

do {
    let page = try MicrosoftGraphMapping.events(from: json("""
    {"value":[
      {"id":"m1","subject":"Review","isAllDay":false,"type":"occurrence","seriesMasterId":"master1","changeKey":"ck1",
       "body":{"contentType":"text","content":"  Notes here  "},"location":{"displayName":"Teams"},
       "start":{"dateTime":"2026-11-17T15:00:00.0000000","timeZone":"UTC"},
       "end":{"dateTime":"2026-11-17T16:00:00.0000000","timeZone":"UTC"}},
      {"id":"m2","subject":"Holiday","isAllDay":true,"type":"singleInstance",
       "start":{"dateTime":"2026-12-24T00:00:00.0000000","timeZone":"UTC"},
       "end":{"dateTime":"2026-12-26T00:00:00.0000000","timeZone":"UTC"}}
    ]}
    """), calendar: outlookCalendar)
    check(page.items.count == 2, "Graph events")
    let review = page.items[0]
    check(review.start == CalendarDates.parseRFC3339("2026-11-17T15:00:00Z"), "Graph UTC times")
    check(review.seriesID == "master1" && review.version == "ck1", "occurrence keeps its series and change key")
    check(review.notes == "Notes here" && review.location == "Teams", "notes and location")
    let holiday = page.items[1]
    check(holiday.isAllDay && holiday.seriesID == nil, "single all-day event")
    check(holiday.start == local(2026, 12, 24) && holiday.end == local(2026, 12, 26), "Graph all-day dates float")
} catch {
    check(false, "Graph events threw \(error)")
}

do {
    let timed = EventDraft(title: "Call", start: CalendarDates.parseRFC3339("2026-11-18T08:30:00Z")!,
                           end: CalendarDates.parseRFC3339("2026-11-18T09:00:00Z")!, isAllDay: false, notes: "Agenda")
    let body = object(MicrosoftGraphMapping.body(for: timed))
    let start = body["start"] as? [String: Any]
    check(start?["dateTime"] as? String == "2026-11-18T08:30:00" && start?["timeZone"] as? String == "UTC", "Graph timed body in UTC")
    check((body["body"] as? [String: Any])?["content"] as? String == "Agenda", "Graph notes")
    check(body["isAllDay"] as? Bool == false, "Graph all-day flag")

    let paris = TimeZone(identifier: "Europe/Paris")!
    let allDay = EventDraft(title: "Off", start: local(2026, 11, 20), end: local(2026, 11, 21), isAllDay: true)
    let dayStart = (object(MicrosoftGraphMapping.body(for: allDay, timeZone: paris))["start"] as? [String: Any])
    check(dayStart?["timeZone"] as? String == "Europe/Paris", "Graph all-day uses the local time zone")
    check((dayStart?["dateTime"] as? String)?.hasSuffix("T00:00:00") == true || TimeZone.current != paris,
          "Graph all-day starts at midnight")
}

// MARK: - Shared model

do {
    let overnight = SyncEvent(accountID: "a", calendarID: "c", remoteID: "1", title: "Flight",
                              start: local(2026, 11, 17, 22), end: local(2026, 11, 18, 6), isAllDay: false)
    check(overnight.days().map(\.iso) == ["2026-11-17", "2026-11-18"], "an overnight event appears on both days")
    let toMidnight = SyncEvent(accountID: "a", calendarID: "c", remoteID: "2", title: "Evening",
                               start: local(2026, 11, 17, 20), end: local(2026, 11, 18, 0), isAllDay: false)
    check(toMidnight.days().map(\.iso) == ["2026-11-17"], "ending at midnight does not spill into the next day")
    let draft = EventDraft(title: "x", start: local(2026, 11, 17, 9), end: local(2026, 11, 17, 10), isAllDay: false)
    let moved = draft.moved(to: local(2026, 11, 19, 14))
    check(moved.start == local(2026, 11, 19, 14) && moved.end == local(2026, 11, 19, 15), "moving keeps the duration")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
