# Privacy Policy

*Last updated: 22 November 2026 · applies to LP 1.0.1 and later*

## The short version

- **LP has no servers, no accounts, no analytics, no ads and no tracking.** Nobody — including
  the people who make LP — receives your notes, boards, calendar or anything about how you use it.
- **Your notes and boards are files in a folder you choose, on your Mac.** LP reads and writes
  them there and nowhere else.
- **LP only goes online for what you use:** to sync the calendar accounts you connect (Google,
  Microsoft), to publish a board's progress page when you share one — to your own Google Drive
  or GitHub — and, once a day unless you turn it off, to ask LP's public GitHub page whether
  there is a new version. Apple Calendar never leaves your Mac through LP.
- **LP takes only what it needs** for each of those, keeps it on your Mac, and lets you remove it.

## Who this is about

LP is free, open-source software (MIT License) that runs entirely on your Mac. It is not a
service: there is no "LP company" or server that collects or stores data. When you connect
Google, Microsoft or GitHub, LP talks to them **directly from your Mac**, with credentials that
belong to you. Those companies handle the data they hold under their own privacy policies:
[Google](https://policies.google.com/privacy) ·
[Microsoft](https://privacy.microsoft.com/privacystatement) ·
[GitHub](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement) ·
[Apple](https://www.apple.com/legal/privacy/).

## What LP keeps, and where

Everything below stays on your Mac.

| What | Where | Why |
|---|---|---|
| Your notes and boards | `.md` files in your workspace folder | They are your documents |
| Board history (activity, daily totals, the shared-page record) | A hidden `.lp` folder in your workspace | Progress tracking |
| Copies of edits that couldn't be saved | LP's own *Recovered* folder (in LP's container, never your workspace) | So you never lose work |
| Events from Google and Microsoft (a year back to two years ahead, plus months you open) | `calendar-cache.json` in LP's container | So your calendar is there offline; kept in sync while online, removed when you disconnect |
| Calendar and GitHub sign-in tokens | Your Mac's Keychain (encrypted by macOS) | To stay connected |
| Settings, workspace bookmarks, which shared pages this Mac may update, when LP last checked for updates | LP's preferences | To remember your choices |
| Which Google Docs in your Drive this Mac made or keeps up to date, by account | LP's preferences | So disconnecting the account can delete them first |
| Reminders | macOS notifications, scheduled on your Mac | To remind you |
| Widget data (today's tasks, the next events from every calendar — Apple's too — and board progress) | `~/Library/Group Containers/<team ID>.LTF.Local-Productivity/`, only when LP is signed with your team | To draw the widgets |

LP's container is `~/Library/Containers/LTF.Local-Productivity/`. Apple Calendar events aren't
copied into LP's calendar cache: LP reads them from macOS when it needs them. (When LP is signed
with your team, the widgets' data holds the next few events, from every calendar, so widgets can
show them — kept up to date, also when an account is disconnected.)

## Connected calendar accounts

You can connect Apple Calendar, Google Calendar and Microsoft Outlook. In plain words:

- **Apple Calendar** — LP asks macOS for access to your calendars and reads and writes them on
  your Mac, including Google, Exchange and other accounts you add in System Settings → Internet
  Accounts. macOS does the syncing; LP itself sends nothing.
- **Google and Microsoft** — you click Connect and sign in on Google's or Microsoft's own page, in
  a window LP asks macOS to keep private. For Google, LP signs in through its own app registration
  (a public "client ID", no secret), once Google has finished reviewing LP — until then, or by choice, yours, set under Advanced; for Microsoft,
  through your own registration for now (LP's own comes in a later version). LP then reads your
  calendars and their events, and changes events you edit in LP, by calling Google's or
  Microsoft's API directly from your Mac. There is no server in between: your sign-in stays in
  your Mac's Keychain, and the makers of LP never see it or your data.
- LP asks for **the smallest permissions that work**: Google — *see your list of calendars* and
  *view and edit events* (not the permission to change calendars or who they are shared with);
  Microsoft — *calendars* and *stay signed in* (not your profile). Microsoft's calendar permission
  is broader than LP needs — it would also allow changing calendars and their sharing — because
  Microsoft has nothing narrower that lets an app edit events; LP only reads and edits events.
- **Disconnecting** deletes the tokens from your Keychain and LP's copy of that account's events;
  for Google, LP also asks Google to end its access.

Details, risks and how to remove access completely: [docs/CONNECTED_ACCOUNTS.md](docs/CONNECTED_ACCOUNTS.md).

## Sharing a board

Sharing is off until you turn it on for a board. When you click **Share Progress**, LP publishes the
board's progress page through **your own account** — never through one of LP's:

- **In your Google Drive, as a Google Doc** — through the Google account you connected for the
  calendar, once you allow it (Settings → Sharing → **Allow Google Drive…**). LP asks Google only
  for the **files it creates** (`drive.file`): it can't see or change anything else in your Drive.
- **On GitHub, as a secret gist** — with a GitHub token you created that can only make gists.

Either way it's free, and:

- The page contains the board's **title, lists, card titles, due dates, tags, progress and recent
  activity**. **Card notes are never included.**
- **Anyone who has the link can open it** — no account needed. It isn't listed or searchable, but
  it isn't password-protected: a link that is passed on works for whoever gets it.
- **A Google Doc** can only be read by others, not edited. LP doesn't put your name or email address
  on the page, but Google may show the people who open it which Google account owns the Doc — its
  name, and possibly its email address. If that matters, share from a separate Google account. Its
  earlier versions stay in the Doc's version history, which only you can see. **Stop Sharing**
  deletes the Doc, and disconnecting the Google account in Settings → Calendars first deletes the
  Docs this Mac made or keeps up to date in that Drive.
- **A gist** shows **your GitHub username**, and GitHub **keeps earlier versions** of it in its
  history until you click **Stop Sharing**, which deletes the page and its history. Someone signed
  in to GitHub can comment on it or fork it. A separate free GitHub account just for sharing keeps
  your main username off the page.
- Anyone who opened a page can keep a copy; Stop Sharing can't remove those.
- LP doesn't track who opens the page. Google or GitHub hosts it and sees visits like any website
  (see [Cookies](COOKIES.md)).

To share without any online service, use **Export Report…**: it saves a self-contained HTML file
you can send yourself.

## Updates

Once a day while LP runs (and whenever you choose **LP → Check for Updates…**), LP asks GitHub's
public API for the list of LP's releases. The request carries LP's version number in its
User-Agent and nothing else about you: no account, no identifier, no notes. GitHub, like any
website, sees your IP address (see GitHub's privacy statement above). If there is a new version
and you choose to install it, LP downloads it from GitHub. You can turn the daily check off in
**Settings → General → Updates**; when and what LP last checked stays in LP's preferences.

## Only the data that's needed

- No analytics, telemetry, crash reporting, advertising or third-party code in LP.
- Calendar: your calendars and their events from a year back to two years ahead (so they're there
  offline), plus months you open. LP asks
  Google and Microsoft for only what it shows (title, times, place, notes, link); when it creates an
  event in Outlook, Microsoft sends the new event back in full, and LP keeps only those fields.
  Attendees and organisers are never stored.
- Sharing: card notes are left out; nothing is published until you choose to; in Google Drive LP
  can reach only the files it created.
- Reminders and widgets use what is already on your Mac.
- Logs: LP writes no logs containing your data.

## Cookies

LP uses no cookies or tracking of any kind. See the [Cookie Policy](COOKIES.md).

## Security

LP is sandboxed by macOS and can only reach the folder you chose and files you pick. Tokens are
in the Keychain; connections use HTTPS; sign-in uses PKCE with no secrets in the app; nothing in a
note can make LP read or write outside your workspace or run code. See [SECURITY.md](SECURITY.md).

## Your choices

- **Disconnect** an account in **Settings → Calendars** (the Docs this Mac shared from a Google
  account's Drive are deleted first); **Stop Sharing** a board in its progress panel; **Disconnect**
  GitHub in **Settings → Sharing**.
- **Remove LP's access at the source:** [Google](https://myaccount.google.com/permissions) ·
  [Microsoft personal accounts](https://account.live.com/consent/Manage) ·
  [Microsoft work or school](https://myapps.microsoft.com) ·
  [GitHub tokens](https://github.com/settings/tokens).
- **Remove everything LP keeps:** quit LP, delete the app, delete
  `~/Library/Containers/LTF.Local-Productivity/` (and, if LP was signed with your team — which
  keeps widget data there automatically — `~/Library/Group Containers/<team ID>.LTF.Local-Productivity/`),
  delete the `.lp` folder in your
  workspace, and delete LP's items in Keychain Access (search "Local-Productivity"). Your notes stay
  as they are.

## Google API data

LP's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements. Data from Google is used only to show and edit your
calendar in LP on your Mac, and to publish the progress pages you choose to share to your own
Drive; it is never transferred to anyone else, used for advertising, or read by people.

## Children

LP is not directed at children and collects no information from anyone.

## Changes

Changes to this policy are recorded in the project's [CHANGELOG](CHANGELOG.md) and its history.

## Contact

Questions: open an issue on the project's GitHub page, or contact the maintainer (LTF-Git-Dev)
through GitHub. Please report security problems privately as described in [SECURITY.md](SECURITY.md).
