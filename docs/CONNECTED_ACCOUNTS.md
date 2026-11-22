# Connected accounts

*Last updated: 22 November 2026*

LP keeps your notes on your Mac. It only talks to other services you connect yourself. This page
explains, for each one, what LP can do, what it takes, where that goes, and how to remove access.
The short version is in the [Privacy Policy](../PRIVACY.md).

## At a glance

| Service | Connected how | What LP can do | What LP keeps on your Mac |
|---|---|---|---|
| **Apple Calendar** | macOS asks you to allow calendar access | Read and change events in your Mac's calendars | Nothing extra — macOS already has them |
| **Google Calendar** (and Drive, for sharing) | Click Connect: your own app registration until Google finishes reviewing LP's, then LP's (or still yours); you sign in in a private session | See your list of calendars; view and edit their events; if you allow it, create, update and delete the board pages you share — only those files in your Drive | Those events (cache), tokens in the Keychain; which Docs LP made |
| **Microsoft Outlook** | Your own app registration for now (LP's own comes in a later version); you sign in in a private session | Read and edit your calendars' events; stay signed in | Those events (cache), tokens in the Keychain |
| **GitHub** (sharing boards) | A GitHub token you create that can only make gists | Create, update and delete the gists of boards you share | The token in the Keychain; which page each board has, in the board's history |

LP has no server. Every request goes from your Mac straight to Apple (through macOS), Google,
Microsoft or GitHub over HTTPS — nobody sits in between, and the makers of LP never see anything.

## How LP connects

Google and Microsoft only let an app sign in if it is registered with them. LP is registered with
Google once, by its makers, so you'll just click **Connect Google Account…** and approve on
Google's own page — **once Google finishes reviewing LP; until then this beta uses your own client
ID** (Settings → Calendars → Use Your Own Client ID) or your Mac's Internet Accounts. LP's own
Microsoft registration comes in a later version — see below:

- Your sign-in goes straight from your Mac to Google or Microsoft and stays in your Keychain. LP
  has no server, so the makers of LP never see your sign-in or your data; the registration only
  tells Google and Microsoft which app is asking. Nothing goes through an "LP account" — there
  isn't one.
- A registration's ID is public, like every desktop app's — not a password. LP uses no client
  secret, and sign-in uses PKCE, so nobody can take over a sign-in LP started. Someone could build
  a fake app that shows "LP" on the sign-in page, as with any app: get LP only from its official
  download.
- Google reviews apps that ask for calendar access before they can sign people in without an
  "unverified app" warning. Until Google approves LP, LP doesn't use its Google registration
  (`BuiltInRegistration.googleAwaitingReview`): Google calendars come through your Mac (below), or
  connect with your own client ID.
- **Microsoft:** LP's own registration comes in a later version — for now, connect Outlook with
  your own registration (Advanced) or through your Mac (below). Work or school accounts may need
  their organisation's approval.
- **No registration at all:** add the account in System Settings → Internet Accounts and connect
  **Apple Calendar** in LP — macOS signs in and syncs. (Microsoft 365 work accounts may not sync
  on a Mac until Apple updates macOS for a change Microsoft is making; Drive sharing needs a
  direct Google connection.)
- **Your own registration (Advanced):** Settings → Calendars → Use Your Own Client ID, with the
  steps. For Google, a *Personal mode* project: only your own account can use it, with no review,
  no warning and no 7-day limit. A connection keeps the registration it was made with (its tokens
  remember it), so changing the setting only affects new sign-ins — but board pages shared to
  Google Drive can only be reached through the registration that made them: stop sharing them
  before you switch.

## Apple Calendar

- **Access:** macOS's calendar permission ("full access"), asked for only when you connect.
- **What LP does:** reads events around the months you look at and the weeks around today (for
  reminders and widgets), and creates, changes or deletes events when you do so in LP.
- **Stored:** not in LP's calendar cache — macOS keeps them and syncs them with iCloud or other
  accounts you set up in System Settings. If you use LP's widgets, the next few events (from every
  calendar) are in the widgets' data so they can be shown.
- **Remove:** System Settings → Privacy & Security → Calendars → turn off LP.

## Google Calendar

- **Permissions LP asks for** (and nothing else):
  - `calendar.calendarlist.readonly` — see the list of calendars you have;
  - `calendar.events` — view and edit events on your calendars.
  LP doesn't ask for the full `calendar` permission, which could also change or delete calendars
  and who they are shared with. Only if you allow Google Drive for sharing (Settings → Sharing),
  one more: `drive.file` — see, edit and delete **only the files LP creates** in your Drive.
- **What LP fetches:** your calendar list (name, colour, whether you can edit it) and the events
  from a year back to two years ahead (plus any other months you open), limited to title, times,
  place, notes, a link to the event, and its version.
  Attendees, organisers, attachments and the like are not requested.
- **Where it goes:** a cache in LP's container
  (`~/Library/Containers/LTF.Local-Productivity/Data/Library/Application Support/LP/calendar-cache.json`),
  so the calendar shows at once; the refresh and access tokens in your Keychain.
- **Disconnect** (Settings → Calendars): first deletes the board pages LP shared in that account's
  Drive (if some can't be — offline, say — it asks before going on), then deletes the tokens and
  that account's events from LP — even if its client ID was cleared — and asks Google to end LP's
  access — for that account on your other Macs too, which then need connecting again (they use
  the same registration). A sign-in right after waits for
  that to finish. To be sure, also check
  [Google Account → Third-party connections](https://myaccount.google.com/permissions).
- **Good to know (your own client ID only):** an *External* Google project in *Testing* ends
  sign-ins after 7 days, and publishing one needs a website; a *Personal mode* project has
  neither problem.

## Microsoft Outlook

- **Permissions LP asks for:** `Calendars.ReadWrite` and `offline_access` (stay connected). LP
  doesn't ask to read your profile; it learns which account is connected from your default
  calendar's owner. `Calendars.ReadWrite` is broader than LP needs — it would also allow changing
  calendars and their sharing — but Microsoft has no narrower permission that lets an app edit
  events. LP only reads and edits events.
- **What LP fetches:** your calendars and their events from a year back to two years ahead (plus any
  other months you open), limited to subject, notes, place, times, whether all-day, series, link
  and version. When LP creates an event,
  Microsoft sends the new event back in full; LP keeps only those fields.
- **Where it goes:** the same cache and Keychain as Google.
- **Disconnect:** deletes the tokens and that account's events from LP. Microsoft has no way for an
  app to end its own access, so remove it yourself at
  [Microsoft account → Apps and services](https://account.live.com/consent/Manage) (personal) or
  [My Apps](https://myapps.microsoft.com) (work or school).

## Google Drive (sharing a board)

- **Allowing it:** Settings → Sharing → **Allow Google Drive…** next to a Google account you
  connected for the calendar. Google's page asks for one more permission, `drive.file` — only the
  files LP creates; LP can't see or change anything else in your Drive. In the Google Cloud project
  of your own client ID (if you use one), turn on the Google Drive API first.
- **What LP sends:** for each board you share there, its progress page as a Google Doc named
  "<board> — Progress" (title, lists, card titles, due dates, tags, progress, recent activity —
  never card notes), updated a few seconds after the board changes if you leave automatic updates
  on. The link stays the same.
- **Who can see it:** anyone with the link can read it — not edit it — without signing in; it isn't
  searchable. LP doesn't put your name or email address on the page, but Google may show the people
  who open it which Google account owns the Doc (its name, possibly its email address) — share from
  a separate Google account if that matters. Earlier versions stay in the Doc's version history,
  which only you can see.
- **What LP keeps:** which Docs this Mac made — or keeps up to date ("Keep It Updated From Here") —
  by account, in LP's preferences, so it can delete them. A Doc is on that list from the moment it
  exists, before anyone else can see it.
- **Stop Sharing** deletes the Doc (its link stops working within seconds). **Disconnecting the
  account** in Settings → Calendars deletes those Docs from its Drive first — after waiting for any
  page still being shared, while no new one starts; if some can't be deleted, LP asks before
  disconnecting anyway and says they are still in that Drive.
- **Cost:** free; each page takes a few kilobytes of your Drive storage.

## GitHub (sharing a board)

- **Token:** a classic token with only the `gist` permission, which you create on GitHub and paste
  into Settings → Sharing. It can make gists — nothing else on your account.
- **What LP sends:** for each board you share, its progress page (title, lists, card titles, due
  dates, tags, progress, recent activity — never card notes). It is updated a few seconds after the
  board changes, if you leave automatic updates on.
- **Who can see it:** anyone with the link; it isn't listed or searchable. The page shows your
  GitHub username, and GitHub keeps earlier versions in the page's history until you stop sharing.
  Anyone who opened it can keep a copy, and someone signed in to GitHub can comment on it or fork
  it; Stop Sharing can't remove those. To keep your main username off it, connect a separate free
  GitHub account just for sharing.
- **Other people's sharing** uses their own GitHub accounts. Your token is kept in your Keychain and
  sent only to GitHub, over HTTPS, to make and update your gists — never to viewers or anyone else.
- **Stop Sharing** deletes the page and its history. **Disconnect** in Settings → Sharing removes
  the token from LP; [delete the token on GitHub](https://github.com/settings/tokens) too if you
  no longer need it.
- **Cost:** free — gists are part of every GitHub account, including free ones.

## Without internet

- **Google and Outlook:** while LP is running and online it syncs them in full — a year back to two
  years ahead, about every half hour (also when LP is behind other apps; not while the Mac
  sleeps), and right away with the calendar's Sync button — and keeps that copy on your Mac until
  you disconnect. So the calendar, reminders and widgets work offline.
  Changes need the internet: offline, LP says it couldn't make them and puts the event back as it
  was — they aren't saved for later.
- **Apple Calendar** works fully offline, changes included — macOS keeps it and syncs later. For
  offline editing of Google or Outlook events, add the account in System Settings → Internet
  Accounts and connect Apple Calendar in LP instead of connecting it directly.

## When a service asks LP to slow down

Google, Microsoft and GitHub limit how often an app may call them. If one of them answers "too many
requests", LP waits as long as it asks — at most an hour — before calling it again, and says so:

- **Calendar:** Settings → Calendars shows "The calendar service asked LP to slow down. Please wait
  until …" next to the account. Nothing is sent to that account until then: a sync under way stops,
  and a change you try meanwhile is turned down at once (LP says so and puts the event back). LP
  syncs the account again by itself afterwards.
- **Sharing:** the progress panel shows "GitHub asked LP to slow down. Please wait until …".
  Nothing is sent to GitHub with that token until then, for any board (another token, for another
  account, isn't held up). Automatic updates try again a few times, each waiting longer; after that
  your next change, or Update Now, brings the page up to date.

For calendars you don't need to do anything. A shared page catches up by itself too, unless the
service keeps asking LP to wait: then the progress panel says automatic updates are paused, and
your next change or **Update Now** brings the page up to date. Normally none of this happens: LP
syncs about every 5 minutes while it is in front (a full sync at most every half hour) and updates
a shared page once, 4 seconds after the last change.

## The risks, plainly

- **A connected account works on this Mac.** Anyone who can use your unlocked Mac account can use
  LP and see your calendar. Lock your Mac and keep FileVault on.
- **Tokens last until revoked.** They are encrypted in the Keychain, but if your Mac account is
  compromised they could be used. Disconnecting removes them; revoking at the source (links above)
  makes sure.
- **Events in the cache** are protected by your Mac login and FileVault, like your other files.
- **Reminders and widgets** show event and task titles on screen, including notification banners;
  choose in System Settings → Notifications whether they appear on the lock screen.
- **A shared link can be passed on.** Treat a shared board like anything else you publish.
- **Sign-in privacy depends on your default browser.** LP asks for a private sign-in session;
  Safari honours it, other browsers may not.
- **Widget data:** when LP is signed with your team, it keeps today's tasks and the next events
  (title, time, place) in `~/Library/Group Containers/<team ID>.LTF.Local-Productivity/` for the
  widgets — whether or not you have added a widget. Disconnecting an account removes its events
  there too.

## For developers

The permissions live in `GoogleCalendarMapping.configuration` (the Drive permission only with
`includeDrive`, `GoogleCalendarMapping.driveFileScope`) and `MicrosoftGraphMapping.configuration`,
the fetched fields in `GoogleCalendarMapping.eventListFields` and `MicrosoftGraphMapping.eventFields`,
and Drive's requests in `GoogleDriveMapping`; the calendar and board tests check that they stay
this narrow. Ask
for a broader permission only when a feature truly needs it, and update this page and the privacy
policy in the same change.
