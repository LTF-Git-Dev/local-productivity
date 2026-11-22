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
    check(url.absoluteString.contains("fields=items"), "only the fields LP shows are asked for")
    check(GoogleCalendarMapping.calendarListURL().absoluteString.contains("fields=items"), "and for the calendar list")
    check(GoogleCalendarMapping.primaryCalendarURL().path == "/calendar/v3/users/me/calendarList/primary", "the account's address comes from the calendar list")
    check(GoogleCalendarMapping.eventURL(calendarID: "c", eventID: "e").absoluteString.contains("fields=id"), "reading or changing one event asks only for LP's fields")
    check(GoogleCalendarMapping.insertURL(calendarID: "c").absoluteString.contains("fields=id"), "and so does creating one")
    check(!GoogleCalendarMapping.deleteURL(calendarID: "c", eventID: "e").absoluteString.contains("fields"), "deleting sends no field mask (nothing comes back)")
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
    check(try MicrosoftGraphMapping.accountName(from: json(#"{"owner":{"name":"Me","address":"me@outlook.com"}}"#)) == "me@outlook.com",
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

// MARK: - Only what is needed

do {
    let google = GoogleCalendarMapping.configuration(clientID: "123-abc.apps.googleusercontent.com")
    check(google?.scopes == ["https://www.googleapis.com/auth/calendar.calendarlist.readonly", "https://www.googleapis.com/auth/calendar.events"],
          "Google: the calendar list (read only) and events — not the full calendar permission: \(google?.scopes ?? [])")
    let microsoft = MicrosoftGraphMapping.configuration(clientID: "00000000-0000-0000-0000-000000000001", bundleID: "LTF.Local-Productivity")
    check(microsoft?.scopes == ["offline_access", "https://graph.microsoft.com/Calendars.ReadWrite"], "Microsoft: calendars only, no profile")
    check(MicrosoftGraphMapping.defaultCalendarURL().absoluteString.contains("/me/calendar?"), "the account's address comes from its calendar")
    if let google, let request = OAuthRequests.revocation(google, token: "refresh-1") {
        check(request.url?.absoluteString == "https://oauth2.googleapis.com/revoke" && request.httpMethod == "POST", "disconnecting Google ends LP's access there")
        check(String(data: request.httpBody ?? Data(), encoding: .utf8) == "token=refresh-1", "with the token in the body, not the address")
    } else {
        check(false, "Google has a revocation request")
    }
    check(microsoft.flatMap { OAuthRequests.revocation($0, token: "t") } == nil, "Microsoft can't be asked, so nothing is sent")
    let stored = OAuthRequests.revocation(at: GoogleCalendarMapping.revocationURL, token: "old-refresh")
    check(stored.url == GoogleCalendarMapping.revocationURL && String(data: stored.httpBody ?? Data(), encoding: .utf8) == "token=old-refresh",
          "an account whose client ID was cleared can still have its access ended (no client ID needed)")
}

// MARK: - Full sync

do {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let now = ISO8601DateFormatter().date(from: "2026-11-19T10:00:00Z")!
    let range = CalendarSyncRange.full(around: now, calendar: utc)
    check(ISO8601DateFormatter().string(from: range.start) == "2025-11-01T00:00:00Z", "a full sync starts a year back: \(range.start)")
    check(ISO8601DateFormatter().string(from: range.end) == "2028-12-01T00:00:00Z", "and ends two years ahead: \(range.end)")
    check(CalendarSyncRange.needsFullSync(lastFullSync: nil, now: now), "an account never synced (or asked to be) gets a full sync")
    check(!CalendarSyncRange.needsFullSync(lastFullSync: now.addingTimeInterval(-10 * 60), now: now), "not again ten minutes later")
    check(CalendarSyncRange.needsFullSync(lastFullSync: now.addingTimeInterval(-31 * 60), now: now), "but after half an hour")

    func event(_ id: String, _ day: String, account: String = "google:me", calendar: String = "google:me|cal") -> SyncEvent {
        let start = ISO8601DateFormatter().date(from: day + "T09:00:00Z")!
        return SyncEvent(accountID: account, calendarID: calendar, remoteID: id, seriesID: nil, title: id, start: start,
                         end: start.addingTimeInterval(3600), isAllDay: false)
    }
    let window = DateInterval(start: ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!,
                              end: ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!)
    let existing = [event("old-far", "2024-03-10"), event("in-window-deleted", "2026-11-20"), event("kept-later", "2027-06-01"),
                    event("hidden", "2027-06-02", calendar: "google:me|hidden"), event("other", "2026-11-20", account: "microsoft:me", calendar: "microsoft:me|c")]
    let merged = SyncEvent.merging([event("new", "2026-11-25"), event("kept-later", "2027-06-01")], over: [window],
                                   calendars: ["google:me|cal"], into: existing, account: "google:me")
    let ids = Set(merged.map(\.remoteID))
    check(ids.contains("old-far") && ids.contains("kept-later"), "events outside what was fetched are kept until disconnect: \(ids.sorted())")
    check(!ids.contains("in-window-deleted"), "inside what was fetched, the source decides (deleted there, gone here)")
    check(ids.contains("new"), "and new events arrive")
    check(merged.filter { $0.remoteID == "kept-later" }.count == 1, "an event fetched again isn't doubled")
    check(!ids.contains("hidden"), "a hidden or removed calendar's events go")
    check(ids.contains("other"), "other accounts are untouched")
}

// MARK: - Slow down (rate limits)

do {
    let now = Date(timeIntervalSince1970: 1_800_000_000)  // Fri, 15 Jan 2027 08:00:00 GMT
    func headers(_ values: [String: String]) -> (String) -> String? {
        let lowered = Dictionary(uniqueKeysWithValues: values.map { ($0.key.lowercased(), $0.value) })
        return { lowered[$0.lowercased()] }
    }
    func limit(_ status: Int, _ values: [String: String] = [:], body: String = "") -> TimeInterval? {
        RateLimit.retryDate(status: status, header: headers(values), body: Data(body.utf8), now: now)?.timeIntervalSince(now)
    }
    check(limit(200) == nil && limit(200, ["Retry-After": "30"]) == nil, "a success is never a limit")
    check(limit(429, ["Retry-After": "120"]) == 120, "429 waits as long as Retry-After says")
    check(limit(429, ["retry-after": "Fri, 15 Jan 2027 08:05:00 GMT"]) == 300, "Retry-After can be a date")
    check(limit(429) == RateLimit.defaultWait, "429 without a time waits a minute")
    check(limit(429, ["Retry-After": "soon"]) == RateLimit.defaultWait, "an unreadable time waits a minute")
    check(limit(429, ["Retry-After": "0"]) == 1 && limit(429, ["Retry-After": "-50"]) == 1, "never less than a second")
    check(limit(429, ["Retry-After": "999999"]) == RateLimit.longestWait, "never more than an hour")
    // GitHub: short-term limits come as 403 + Retry-After; a used-up hour as remaining 0 + reset.
    check(limit(403, ["Retry-After": "60"]) == 60, "GitHub's 403 with Retry-After is a limit")
    check(limit(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000900"]) == 900, "GitHub's used-up allowance waits for its reset")
    check(limit(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800999999"]) == RateLimit.longestWait, "a far reset still waits at most an hour")
    check(limit(403, ["X-RateLimit-Remaining": "12"]) == nil, "a 403 with allowance left is a real \u{201C}not allowed\u{201D}")
    // Google names the limit in the error.
    check(limit(403, body: #"{"error":{"code":403,"errors":[{"domain":"usageLimits","reason":"rateLimitExceeded"}]}}"#) == RateLimit.defaultWait,
          "Google's rateLimitExceeded is a limit")
    check(limit(403, body: #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#) == RateLimit.defaultWait, "so is userRateLimitExceeded")
    check(limit(403, body: #"{"error":{"code":403,"status":"RESOURCE_EXHAUSTED"}}"#) == RateLimit.defaultWait, "and RESOURCE_EXHAUSTED")
    check(limit(403, body: #"{"error":{"code":403,"errors":[{"reason":"forbidden"}]}}"#) == nil, "Google's forbidden stays a permissions problem")
    // Microsoft sometimes slows apps down with a 503 and Retry-After.
    check(limit(503, ["Retry-After": "30"]) == 30, "503 with Retry-After is a limit")
    check(limit(503) == nil && limit(500, ["Retry-After": "30"]) == nil, "an outage isn't")
    // GitHub's secondary limits can come as a 403 that says so only in its message.
    check(limit(403, body: #"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}"#) == RateLimit.defaultWait,
          "GitHub's secondary-limit message is a limit")
    check(limit(403, body: #"{"message":"API rate limit exceeded for user ID 1."}"#) == RateLimit.defaultWait, "so is its hourly one")
    check(limit(403, body: #"{"message":"Resource not accessible by personal access token"}"#) == nil, "GitHub's real \u{201C}not allowed\u{201D} stays one")
    let message = CalendarSyncError.rateLimited(now).errorDescription ?? ""
    check(message.contains("slow down") && message.contains("wait until"), "the message says what happened and until when")
}

// MARK: - Which app registration signs in

do {
    let lp = "111-lp.apps.googleusercontent.com", mine = "222-mine.apps.googleusercontent.com"
    check(AppRegistration.clientID(own: "", builtIn: lp) == lp, "with no client ID of your own, LP's own registration is used")
    check(AppRegistration.clientID(own: "  \(mine) \n", builtIn: lp) == mine, "your own client ID wins over LP's (trimmed)")
    check(AppRegistration.clientID(own: "", builtIn: nil) == nil && AppRegistration.clientID(own: " ", builtIn: "  ") == nil,
          "with neither, there is nothing to sign in with")

    let signedIn = try? OAuthRequests.tokens(from: json(#"{"access_token":"a1","expires_in":3600,"refresh_token":"r1"}"#),
                                             previousRefreshToken: nil, clientID: mine)
    check(signedIn?.clientID == mine, "tokens remember the registration that issued them")
    let encoded = signedIn.flatMap { try? JSONEncoder().encode($0) }
    check(encoded.flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }?.clientID == mine, "and keep it when saved")
    let refreshed = try? OAuthRequests.tokens(from: json(#"{"access_token":"a2","expires_in":3600}"#), previousRefreshToken: "r1",
                                              previousScopes: signedIn?.scopes, clientID: signedIn?.clientID)
    check(refreshed?.clientID == mine && refreshed?.refreshToken == "r1", "a refresh keeps the registration")
    let old = json(#"{"accessToken":"a0","refreshToken":"r0","expiresAt":0}"#)
    check((try? JSONDecoder().decode(OAuthTokens.self, from: old))?.clientID == nil, "tokens saved by LP 1.0.0 still load (no registration noted)")
    let legacy = try? JSONDecoder().decode(OAuthTokens.self, from: old)
    check(legacy?.pinned(to: mine).clientID == mine && legacy?.pinned(to: mine).refreshToken == "r0",
          "LP 1.0.0's tokens are pinned to the registration they're first loaded with")
    check(signedIn?.pinned(to: lp).clientID == mine, "a registration already noted never changes")
    typealias Replace = ConnectionReplacement
    check(Replace.allowingDrive(chosen: "google:a", expected: "google:a", liveClientID: mine, requested: mine, driveWorkRunning: false) == .replace,
          "allowing Drive adds it to the account's own connection")
    check(Replace.allowingDrive(chosen: "google:a", expected: "google:a", liveClientID: nil, requested: lp, driveWorkRunning: false) == .replace,
          "or connects an account that isn't attached right now")
    check(Replace.allowingDrive(chosen: "google:b", expected: "google:a", liveClientID: nil, requested: mine, driveWorkRunning: false) == .otherAccount,
          "another account chosen on Google's page is refused")
    check(Replace.allowingDrive(chosen: "google:a", expected: "google:a", liveClientID: lp, requested: mine, driveWorkRunning: false) == .superseded,
          "allowing Drive never moves an account to another registration (connected again meanwhile)")
    check(Replace.connecting(liveClientID: mine, requested: lp, hasDriveWork: true, driveWorkRunning: false) == .registrationInUse,
          "Connect won't move an account whose Drive pages — or one being made — need its registration")
    check(Replace.connecting(liveClientID: mine, requested: lp, hasDriveWork: false, driveWorkRunning: false) == .replace
          && Replace.connecting(liveClientID: lp, requested: lp, hasDriveWork: true, driveWorkRunning: false) == .replace
          && Replace.connecting(liveClientID: nil, requested: lp, hasDriveWork: true, driveWorkRunning: true) == .replace,
          "but moves it when nothing depends on the old one, or reconnects through the same")
    check(Replace.connecting(liveClientID: lp, requested: lp, hasDriveWork: true, driveWorkRunning: true) == .busy
          && Replace.allowingDrive(chosen: "google:a", expected: "google:a", liveClientID: mine, requested: mine, driveWorkRunning: true) == .busy,
          "no live connection is replaced while a Drive page is being made or updated through it")
    check(CalendarSyncError.registrationInUse("a@example.com").errorDescription?.contains("Stop sharing them") == true,
          "connecting an account through another registration says why it can't while its Drive pages need the old one")
    check(GoogleCalendarMapping.configuration(clientID: AppRegistration.clientID(own: "", builtIn: lp) ?? "")?.clientID == lp,
          "LP's registration signs in like any other")
}

// MARK: - Permissions granted, and the optional Drive permission

do {
    let granted = try? OAuthRequests.tokens(from: json(#"{"access_token":"a1","expires_in":3600,"refresh_token":"r1","scope":"https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/drive.file"}"#),
                                            previousRefreshToken: nil)
    check(granted?.scopes == ["https://www.googleapis.com/auth/calendar.events", "https://www.googleapis.com/auth/drive.file"],
          "the permissions the person granted are kept")
    let refreshed = try? OAuthRequests.tokens(from: json(#"{"access_token":"a2","expires_in":3600}"#), previousRefreshToken: "r1",
                                              previousScopes: granted?.scopes)
    check(refreshed?.scopes == granted?.scopes && refreshed?.refreshToken == "r1", "a refresh that doesn't list them keeps them")
    let saved = json(#"{"accessToken":"a0","refreshToken":"r0","expiresAt":0}"#)
    check((try? JSONDecoder().decode(OAuthTokens.self, from: saved))?.scopes == nil, "tokens saved before LP kept track still load")

    let plain = GoogleCalendarMapping.configuration(clientID: "123-abc.apps.googleusercontent.com")
    let drive = GoogleCalendarMapping.configuration(clientID: "123-abc.apps.googleusercontent.com", includeDrive: true, loginHint: "a@example.com")
    check(!(plain?.scopes.contains(GoogleCalendarMapping.driveFileScope) ?? true), "the calendar alone never asks for Drive")
    check(drive?.scopes == (plain?.scopes ?? []) + ["https://www.googleapis.com/auth/drive.file"], "sharing adds only drive.file (files LP creates)")
    check(plain?.extraAuthorizeParameters["include_granted_scopes"] == "true", "connecting again keeps what was granted before")
    check(drive?.extraAuthorizeParameters["login_hint"] == "a@example.com" && plain?.extraAuthorizeParameters["login_hint"] == nil,
          "allowing Drive picks the account it is for")

    let disabled = json(#"{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Google Drive API has not been used in project 1 before or it is disabled.","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","metadata":{"serviceTitle":"Google Drive API","service":"drive.googleapis.com"}}]}}"#)
    check(GoogleAPIProblem.disabledService(in: disabled) == "Google Drive API", "an API that isn't turned on is named")
    check(GoogleAPIProblem.disabledService(in: json(#"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#)) == "The Google API LP needs",
          "also in Google's older wording")
    check(GoogleAPIProblem.disabledService(in: json(#"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}]}}"#)) == nil,
          "a missing permission is something else")
    check((CalendarSyncError.serviceDisabled("Google Drive API").errorDescription ?? "").contains("turned on"), "and the message says what to do")
}

// MARK: - Waits, per who was asked

MainActor.assumeIsolated {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    check(ServicePause.until("calendar.a", now: now) == nil, "nothing to wait for at first")
    let long = ServicePause.record("calendar.a", until: now.addingTimeInterval(900), now: now)
    check(long == now.addingTimeInterval(900) && ServicePause.until("calendar.a", now: now) == long, "a wait is kept")
    // Two requests were on their way; the later answer asks for less.
    let after = ServicePause.record("calendar.a", until: now.addingTimeInterval(30), now: now.addingTimeInterval(5))
    check(after == now.addingTimeInterval(900), "a later, shorter answer doesn't shorten the wait")
    check(ServicePause.record("calendar.a", until: now.addingTimeInterval(1200), now: now) == now.addingTimeInterval(1200), "a longer one lengthens it")
    check(ServicePause.until("calendar.b", now: now) == nil && ServicePause.until("github.x", now: now) == nil,
          "another account or token isn't held up")
    check(ServicePause.until("calendar.a", now: now.addingTimeInterval(1201)) == nil, "and the wait ends")
    // Once over, a new answer starts a new wait, even a shorter one.
    check(ServicePause.record("calendar.a", until: now.addingTimeInterval(1260), now: now.addingTimeInterval(1201)) == now.addingTimeInterval(1260),
          "after it ends, a new wait is a new wait")
    // Waits per credential (a GitHub token, a sign-in still finding its account) go by a fingerprint.
    let one = ServicePause.fingerprint("token-one"), two = ServicePause.fingerprint("token-two")
    check(one.count == 16 && one != two && one == ServicePause.fingerprint("token-one"), "credentials get stable, different names")
    check(!one.contains("token"), "that don't contain the credential")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
