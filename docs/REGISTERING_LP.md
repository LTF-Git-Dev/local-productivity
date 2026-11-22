# Registering LP with Google and Microsoft

*For the maintainer. Last updated: 22 November 2026.*

LP itself is registered with Google (since 20 November 2026), so **Connect Google Account…** will
work without any setup — but until Google approves LP, builds don't use that registration for new
sign-ins (`BuiltInRegistration.googleAwaitingReview`; connections made earlier keep syncing). Its Microsoft registration is planned for the next update:
Microsoft blocked creating the account on the first try (its anti-abuse check) — retry later from
another network, then follow the Microsoft section below. Its client IDs live in
`Local Productivity/Calendar/Sync/BuiltInRegistration.swift` (`shippedGoogleClientID`,
`shippedMicrosoftClientID`). While they are `nil`, LP behaves as before: people need their own
client ID (Settings → Calendars → Use Your Own Client ID).

**Client IDs are public, never secret.** A desktop app can't keep a secret, so LP has no client
secret anywhere and every sign-in uses PKCE. Anyone can read the IDs in the app. Someone could
build a fake app with them, as with any desktop app; Google and Microsoft can suspend a misused
registration, and LP can switch to new IDs (see *Replacing the IDs*).

## What you need first

1. **The support address `ltf.dev.supp@gmail.com`** — LP's dedicated public support address.
   Google shows it to everyone on its sign-in page.
2. **The website** — Google's review needs a home page and privacy policy on a domain you own:
   - `Scripts/make-site.py` builds it from `PRIVACY.md`, `TERMS.md`, `COOKIES.md`,
     `docs/CONNECTED_ACCOUNTS.md` and `SECURITY.md` into `../LTF-Git-Dev.github.io`. Set
     `SUPPORT_EMAIL` in the script to the support address. Its screenshots come from
     `Scripts/make-site-shots.sh` (run it first whenever LP's look changes).
   - That folder is the public GitHub Pages repository `LTF-Git-Dev/LTF-Git-Dev.github.io`, served
     at **https://ltf-git-dev.github.io**. It holds only those pages, their stylesheet, the icon and
     the screenshots, never the app's code, and loads nothing from other sites.
   - Whatever its design, the home page must keep what Google checks: the name **LP**, what LP
     does, each permission and what LP does with it, the Limited Use statement, and links to the
     privacy policy and terms.
     Commit to it with GitHub's noreply address, not a personal one.
   - Run the script again whenever the policies change, and push the site.
3. **Google Search Console** (search.google.com/search-console): add the URL-prefix property
   `https://ltf-git-dev.github.io/`, choose the **HTML file** method, put the file's name in
   `SEARCH_CONSOLE_FILES` in the script, rebuild, push, then click **Verify**. Use the same Google
   account as the Cloud project.

## Google

In [Google Cloud](https://console.cloud.google.com), with the same Google account:

1. **New project** "LP" — a normal project, not a Personal mode one.
2. **Turn on the APIs:**
   [Google Calendar API](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com) and
   [Google Drive API](https://console.cloud.google.com/apis/library/drive.googleapis.com) → Enable.
3. **Google Auth Platform → Branding:**
   - App name **LP**; user support email: the support address; logo: optional — LP's is
     `../LP Design/brand/exports/google-branding-logo-120.png` (the Orbit Bear head, 120 × 120
     PNG). Google has to verify a logo; LP goes through verification anyway, so add it before
     submitting rather than after (changing the branding later means another review).
   - App home page `https://ltf-git-dev.github.io/`, privacy policy
     `https://ltf-git-dev.github.io/privacy.html`, terms `https://ltf-git-dev.github.io/terms.html`.
   - Authorized domain `ltf-git-dev.github.io`; developer contact: the support address.
4. **Audience:** user type **External**.
5. **Data Access → Add or remove scopes:** `.../auth/calendar.calendarlist.readonly`,
   `.../auth/calendar.events`, `.../auth/drive.file`. Exactly these — the app asks for no others.
6. **Clients → Create client:** type **iOS**, bundle ID `LTF.Local-Productivity`. Copy the client
   ID (it ends in `.apps.googleusercontent.com`).
7. **Audience → Publish app** (Branding must be complete). From now on it works for up to 100
   people, with an "unverified app" warning, until the review passes.
8. **Verification Center → Prepare for verification:** answer with the texts below and the video.
   Google's reviewers write to the support/developer address; reply there.

### Why LP needs each permission (paste into the form)

- **`calendar.calendarlist.readonly`** — LP shows the user's calendars in its calendar view and in
  its settings, where the user chooses which calendars appear and which one new events go into.
  LP only reads the list (name, colour, whether it can be edited); it never changes calendars or
  their sharing.
- **`calendar.events`** — LP is a calendar app: it shows the events of the user's calendars next
  to their notes and lets the user create, edit, move and delete events, which LP saves back to
  Google Calendar. `calendar.events.readonly` can't save the user's edits, and
  `calendar.app.created` covers only calendars LP creates, not the user's existing ones. LP doesn't
  ask for the broader `calendar` scope, which would also allow changing calendars and who they are
  shared with.
- **`drive.file`** (non-sensitive) — only when the user chooses to share a board's progress: LP
  creates a Google Doc in the user's Drive, keeps it up to date, and deletes it when the user
  stops sharing or disconnects. It can't see any other file in the Drive.
- **Data handling** — LP runs only on the user's Mac and has no servers: Google data goes directly
  between the Mac and Google's APIs, is stored only on that Mac (a calendar cache and tokens in
  the Keychain), and is never transferred, sold, used for ads or read by people. LP follows the
  Google API Services User Data Policy, including the Limited Use requirements (see the privacy
  policy).

### Demo video (confirmed with the reviewer Codex, 20 November 2026)

What Google checks (its *Demo Video*, *Sensitive scope verification* and *Verification
requirements* pages): the whole grant flow in **English** (the consent screen's language switch,
bottom left); the app name **LP**, the same app and branding as in Google Cloud; the **OAuth client
ID in the browser's address bar** on the consent screen; and **each permission's feature working**.
Voice isn't needed: English on-screen captions are enough. Upload to YouTube as **Unlisted** and
check it plays while signed out. Never show passwords, 2-step or recovery codes, tokens, other tabs,
profile pictures or the Cloud project's members.

LP's buttons stay plain text ("Connect Google Account…", "Allow Google Drive…"): Google's guidance
for apps using its APIs says to use plain text that doesn't overstate the relationship; the "G"
button rules are for Sign in with Google, which LP doesn't use.

Before recording:
1. **Google Cloud:** the iOS client with LP's shipped ID and bundle ID (don't delete working
   clients; note unused ones), Calendar and Drive APIs on, exactly the three scopes, Branding
   complete and **verified** (decide on the logo first), Audience *In production*.
2. **Demo account:** the support account in English, with a second calendar and a few
   non-recurring events this week, and LP removed from its third-party access (so both consent
   screens appear in full).
3. **A separate Mac user** ("LP Demo") with a production-equivalent LP build (LP's own client ID —
   not the harness or `LP_DEMO_REGISTRATION`) and a synthetic workspace it can write to. Your own
   Mac user won't do: LP's settings there may hold your own client ID, and old tokens remember
   their registration.
4. **Rehearse** to find the browser whose sign-in window shows `client_id=` in its address bar
   (Chrome as default, then Safari); if none does, stop and settle the evidence with Google first.
   Afterwards delete rehearsal Docs, disconnect, and remove LP from the account's access again.

Shot list, about 4–6 minutes (hold the client ID and the permissions 5–8 s, zoomed):

| Part | Show | Time |
|---|---|---|
| Intro | LP's website (name, Privacy Policy link), then LP's window | 10–15 s |
| Calendar authorization | Connect Google Account… → client ID in the address bar → English consent with both Calendar permissions → back in LP (cut the password) | 45–75 s |
| Calendar list | Settings → Calendars: the two Google calendars, Show in LP, where new events go | 20–30 s |
| Events | A Google event in LP; create, edit and delete a separate non-recurring event; each change on calendar.google.com | 60–90 s |
| Drive authorization | Settings → Sharing → Allow Google Drive… → same client ID → second consent | 30–45 s |
| Shared Doc | Share Progress… → open the Doc → change a card → the same Doc updates → Stop Sharing → the Doc is gone | 45–75 s |
| Finish | Disconnect in LP | 10–15 s |

### What was submitted (2026-11-20)

The owner recorded one take in their own Mac user (not a separate one: LP's settings there were
backed up and cleared first, then restored) with the 1.0.1 Release build. Safari, the fallback
browser, showed only `accounts.google.com` in the sign-in window. Claude cut it to 81 seconds
(`../Video/LP demo - captioned.mp4`: English captions at the bottom, both password entries and
Safari's "Save Password?" removed, no audio). It shows both consent screens, the connected
calendar, Allow Google Drive… and a board shared as a Google Doc. **Not shown:** the client ID in
the address bar, creating/editing/deleting an event, and the Doc being opened, updated and
removed. If Google asks for these, record a Part 2 from the shot list above (Chrome as the default
browser for the address bar) and append it.

## Microsoft

In the [Microsoft Entra admin center](https://entra.microsoft.com) (a free Azure account may be
needed to get a directory):

1. **App registrations → New registration:** name **LP**; supported account types **Accounts in
   any organizational directory and personal Microsoft accounts**; no redirect URI yet.
2. **Authentication → Add a platform → iOS / macOS:** bundle ID `LTF.Local-Productivity`. Leave
   "Allow public client flows" as it is; there is no secret to create.
3. **API permissions → Add → Microsoft Graph → Delegated:** `Calendars.ReadWrite` (plus
   `offline_access`, which sign-in asks for by itself). Remove `User.Read` if it was added — LP
   doesn't use it.
4. **Overview:** copy the **Application (client) ID**.

Without publisher verification (it needs a verified organisation in Microsoft's partner program),
personal accounts connect right away, shown as unverified; work or school accounts may need their
organisation's approval.

## Putting the IDs into LP

1. Set `shippedGoogleClientID` and `shippedMicrosoftClientID` in `BuiltInRegistration.swift`, on a
   branch. Once Google has approved LP, also set `googleAwaitingReview` to `false` (it keeps LP's
   Google registration out of builds until then).
2. Test with real accounts: connect Google with one click (no client ID of your own set), allow
   Drive, share and stop sharing a board, run the Drive self-test (`LP_DRIVE_SELFTEST=1`, see
   CLAUDE.md); connect a personal Microsoft account; disconnect both.
3. Then the usual: tests, Codex review, the security checklist, and a beta.

## Replacing the IDs

If a registration is misused or lost: create a new client, put its ID in `BuiltInRegistration.swift`
and release. Connections keep working with the registration that issued their tokens until that
client is deleted; then people connect again. Board pages shared to Google Drive belong to the
registration that made them — delete the old client only after the release that replaces it has
been out for a while.
