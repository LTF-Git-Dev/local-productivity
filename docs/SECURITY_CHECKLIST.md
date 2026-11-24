# Security checklist

*The owner's rule, set on 19 November 2026: go through this list before any version is finalized —
before its beta is published, and again before the official release. Look into every point whose
condition applies, fix what is found (with a test), and add the result to the record at the end.*

LP is a Mac app with **no server, no accounts of its own, no database and no payments**. The list
was written for apps that have those, so each point below says what it means for LP today. If LP
ever gains a server, accounts, a database or payments, the point applies exactly as written.

## How to run it

```sh
Scripts/test.sh                                   # every suite, 0 failed
LP_TEST_VERBOSE=1 Scripts/test.sh ownership       # point 7: prints every "person B" check
git log -p --all | grep -nE 'ghp_[A-Za-z0-9]{20,}|github_pat_|gho_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|BEGIN [A-Z ]*PRIVATE KEY|client_secret|xox[bpa]-|sk_(live|test)_|AKIA[0-9A-Z]{16}'
git log --all --name-only --format= | sort -u | grep -iE '\.env|\.p12$|\.pem$|\.key$|\.mobileprovision$|credentials|secret'
grep -rn 'ProcessInfo.processInfo.environment\[' --include='*.swift' "Local Productivity" Shared LPWidgets
Scripts/deploy.sh <version> --dry-run             # builds the app to publish and checks what's in it
```

Then read the points below against what changed in the version.

## The seven points

### 1. Secrets

> List every env var in this project and which ones reach the browser. Move every secret behind a
> server route. Rotate anything that was ever committed.

**For LP.** LP has no secrets of its own. The only credentials are each person's own (Google and
Microsoft sign-in tokens, a GitHub token): kept in the Keychain, never written to files or logs,
sent only to the service they belong to, over HTTPS. Client IDs are public identifiers — LP's own
(`BuiltInRegistration`) or the person's own; sign-in uses PKCE, so there are no client secrets. "Reaching the browser" means what leaves
the Mac for others to see: a shared progress page, an exported report, and the app published on
GitHub.

**Check.** No secret anywhere in the history (all branches) and no secret-looking files. Every
environment variable is either a test switch read only by Debug builds or a build-script setting.
A Release build contains none of the test switches. The shared page and the report carry the board's
title, lists, card titles, dates, tags, progress and activity — never card notes, file paths or
tokens. `deploy.sh` refuses to publish an app whose signature shows an email address or that
contains anything shaped like a token or private key; the official version is the beta's own app
file (its SHA-256 is in both releases' notes), so what is published is exactly what was tested.

| Variable | Read by | Reaches |
|---|---|---|
| `LP_SNAPSHOT_*`, `LP_WORKSPACE`, `LP_APPEARANCE` | the snapshot harness (Debug only) | nothing; not in Release builds |
| `LP_WIDGET_SNAPSHOT` | widget publisher, inside `#if DEBUG` | a local test file; not in Release |
| `LP_DEMO_CALENDAR_DELAY`, `…_WRITE_DELAY`, `…_LIMIT` | the demo calendar (Debug only) | nothing; not in Release |
| `LP_TEAM_ID` | `build.sh`, `deploy.sh` | the app's signature (a team ID is public in every signed app) |
| `LP_BUILD_LINES`, `LP_SNAPSHOT_LINES` | `build.sh`, `snapshot.sh` | nothing (how much output to show) |

### 2. Ownership

> List every API route and show where each one verifies the caller owns the resource ID it
> touches. Flag any route that trusts a userId from the request.

**For LP.** LP has no API routes. Its "routes" are the ways something from outside reaches it, and
each one is checked:

| Way in | Who could use it | What it may do | Where it's checked |
|---|---|---|---|
| `localproductivity://` links | any web page or app | only show Home, the boards, the calendar or a page inside the workspace — never change anything | `LPLink.destination`, `AppModel.handle(_:)`, `PathSafety.contained` |
| Sign-in replies (Google, Microsoft) | anyone who can send LP a reply | connect only the sign-in LP itself started | `OAuthRequests.code(from:expectedState:)` (state) plus PKCE |
| Share records in the workspace (`.lp/boards/`) | anyone who had the folder | nothing on their own: LP updates or deletes a page — a gist or a Google Doc — only with this Mac's permission for that file, board and page (for a Doc, its Google account too) | `ShareTrust.isTrusted`, `BoardShare.grantKey`, used by `BoardStore.shareIsTrusted` |
| Page IDs from those records | same | go into a GitHub or Google address only if they are that service's kind of ID | `BoardShare.isWellFormed`, `GoogleDriveMapping.isValidFileID`, `BoardShare.pageURL` |
| Paths and links in notes | whoever wrote the note | stay inside the workspace; apps and scripts are shown in Finder, other apps ask first | `PathSafety`, `LinkSafety` |
| Calendar edits | the person, in LP | change an event only through the account connection that fetched it; Google and Microsoft decide who may change which event | `CalendarSyncStore.provider(for:)` and its provider-identity checks |

Nothing trusts an ID that came from outside without one of these checks.

### 3. Database rules

> Show every public table with RLS disabled. Enable RLS on all of them and write policies scoped
> to auth.uid(). Prove it with a query as another user.

**For LP.** There is no database, no table and no user account. What LP keeps, and who can reach
it: the workspace folder (the person's own files, protected by macOS like any folder); LP's
container `~/Library/Containers/LTF.Local-Productivity/` (sandboxed: only LP); the Keychain (LP's
items only, not synced to iCloud); the widgets' App Group (only LP and its widgets, in team-signed
builds). The one thing published is a shared page, which is public to whoever has its link — that
is what sharing is, and it is explained wherever sharing is.

**Check.** The Release build is sandboxed (`codesign -d --entitlements - LP.app | grep app-sandbox`);
no Keychain item sets `kSecAttrSynchronizable`.

### 4. Mass assignment

> Validate every request body with a strict schema that rejects unknown fields. Show me the schema
> per route and the fields a user must never set.

**For LP.** LP receives no request bodies. The equivalent is anything LP reads that someone else
may have written: files in the workspace (front matter, board histories in `.lp/`) and replies from
Google, Microsoft and GitHub. The fields that must never come from them:

| Field | Comes only from |
|---|---|
| Permission to update or delete a shared page | this Mac's preferences (`Workspace.authorizedShares`), written when LP publishes a page here or the person chooses "Keep It Updated From Here" |
| A shared page's address | built from its ID (`BoardShare.pageURL`); the address written in the history is never used |
| Which Google account a Drive page belongs to | the record — but it is part of the permission (`grantKey`), so changing it voids the permission |
| Which file LP reads or writes | a path inside the workspace (`PathSafety`), checked again after resolving links |
| Where a link in a note goes | `LinkSafety`: web links open, links to other apps ask first, apps and scripts are only shown in Finder |

Unknown fields are ignored rather than rejected, on purpose: newer versions of LP add fields to
histories and caches, and older versions must keep reading them. Nothing in an unknown field is
ever used.

### 5. Payments

> Show where every price and amount comes from. Prices must be looked up on the server by product
> ID. Show me the webhook handler verifying the Stripe signature.

**For LP.** None. LP is free: no purchases, no StoreKit, no payment code, no webhooks, and no
third-party code at all (the project has no package dependencies). It costs the owner nothing to
run: there is no server, and everyone connects their own free GitHub, Google or Microsoft account.

**Check.** `grep -rln 'StoreKit\|Stripe' --include='*.swift' .` finds nothing; the project has no
package references.

### 6. Rate limits

> Add rate limiting to login, signup, password reset and every route that calls a paid API. Show
> the limit per route and the response when it's exceeded.

**For LP.** LP has no login, signup or password reset of its own (signing in to Google or Microsoft
happens on their pages, which limit it themselves), and it calls no paid API. What matters is how
often LP calls the services it does use, and what it does when one says "too many requests":

| Service | How often LP calls it | When the service says "slow down" |
|---|---|---|
| Google Calendar, Outlook | one sync at a time; the months shown about every 5 minutes while LP is in front; a full sync at most every 30 minutes, plus the Sync button, a new connection and your own changes | nothing at all is sent for that account — sign-in token refreshes included — until the time asked (`Retry-After`, or GitHub's reset time; one minute if no time is given; never more than an hour) — not the next page of a sync under way, not a change, which is turned down at once and put back. Settings shows "The calendar service asked LP to slow down. Please wait until …"; LP syncs by itself afterwards |
| GitHub (sharing) | one update per board, 4 seconds after the last change; Share, Update Now and Stop Sharing when clicked | nothing is sent with that token until then, for any board (another token isn't held up); the message says until when; automatic updates try again at most 3 times, each waiting longer (8, 16, 32 seconds, or as long as GitHub asks), then wait for the next change |
| Google Drive (sharing) | one update per board, 4 seconds after the last change; Share, Update Now and Stop Sharing when clicked | the same per-account wait as the calendar: nothing is sent for that account until then; automatic updates try again at most 3 times |
| Google, Microsoft sign-in | only when you click Connect, one at a time | their own page |

The rule for "slow down" is `RateLimit.retryDate` (a 429; a 403 with `Retry-After`, a used-up
allowance, Google's `rateLimitExceeded` or GitHub's "secondary rate limit" message; a 503 with
`Retry-After`). The waits are kept by `ServicePause`, per calendar account and per GitHub token,
checked before every request, and a later answer with a shorter wait never shortens one. Both are
tested in the calendar suite.

### 7. Prove it

> Write a test where user A creates a record and user B tries to read, update and delete it.
> Every attempt must return 403 or 404. Run it and show me the output.

**For LP.** Person A and person B are A's Mac and anything that isn't A: someone else's copy of
A's folder, a folder someone hands A, a link on a web page, a forged sign-in reply. LP has no server
to answer 403 or 404, so here "refused" means LP sends nothing at all. GitHub itself also lets only
a gist's owner change or delete it, so B's own token couldn't change A's page either. Reading: a
shared page is meant to be read by whoever has its link, and card notes are never on it.

The suite `ownership` holds these checks. Removing the permission check from `ShareTrust` makes 4
of them fail, so they do catch the mistake they are for. The real app was checked the same way with
the harness: A's folder with a shared page, opened where there's no permission
(`open:Projects/Launch.md ;; share-update ;; share-stop ;; state` → `share=set up elsewhere`, no
request, the record untouched), then allowed (`share-trust ;; share-update` → LP goes ahead).

## Record

### v1.0.3 — 25 November 2026 (official)

The official release is `v1.0.3-beta.2`'s own zip (records below). Verified signed-out: signature,
checksum, the updater's strict check, no secrets or personal email; tests 1,632 / 0 failed from a
clean checkout of the tag; a real in-app update 1.0.2 → 1.0.3 on the owner's Mac (restarted itself,
app byte-identical to the release, settings kept). Codex clean.

### v1.0.3-beta.1 — 25 November 2026 (final testing before the beta)

Changes: Settings one size (scrolls); Notifications on/off switch. No new data, network or file
access; the switch only cancels LP's own pending notifications (`removeAllPendingNotificationRequests`
— LP schedules nothing else). All 11 suites 0 failed (1,632), `ownership` 29 passed; Release build
(1.0.3) signed ad hoc, passes the updater's strict signature check, secret scan clean, no personal
email; `lp-mcp` universal and answering (17 tools). Codex clean after five rounds on the switch's
timing (immediate off, one queue for updates/snoozes/cleanup).
Final testing for beta 2 found that beta 1's quit wait (`.terminateLater`) froze a quit started from
main-thread code (the updater's relaunch, the harness); quitting now cancels synchronously instead —
verified: the test app quits in 2–3 s, including with Notifications off.

### v1.0.2 — 25 November 2026 (official)

The beta's record below applies; since then only the Settings steps (shell-quoted commands, tested
in `safety`) and the removal of Send a Test changed. All suites 0 failed; `ownership` 29 passed;
Codex clean on every change. The official release is `v1.0.2-beta.2`'s own zip.


### v1.0.2-beta.1 — 24 November 2026

LP 1.0.2 = LP for Claude (see the MCP record below) shipped inside LP.app, plus the Settings section.

| # | Result | Found, and what was done |
|---|---|---|
| 1 Secrets | ✅ | None added; the helper has no network access and no keys. |
| 2 Ownership | ✅ | The helper reaches only the workspace the person picks in LP's form each session (MCP elicitation), never anything else; covered by the `mcp` suite. |
| 3 Database rules | ✅ n/a | No database. |
| 4 Mass assignment | ✅ | The setup steps quote every path for the shell (`ClaudeSetup`, tested with hostile folder names). |
| 5 Payments | ✅ n/a | None. |
| 6 Rate limits | ✅ | Unchanged. |
| 7 Prove it | ✅ | All suites 0 failed; `ownership` 29 passed. |


### LP for Claude (MCP) — 24 November 2026 (`feature/lp-mcp`, not released)

| # | Result | Found, and what was done |
|---|---|---|
| 1 Secrets | ✅ | None: no tokens, keys or network access; it reads only the workspace folder it's given. |
| 2 Ownership | ✅ | Only the workspace: every path walked from its folder without following links; hidden, read-only, locked and ACL-protected files refused; a file shared by hard link keeps its other copy untouched. Tested in the `mcp` suite. |
| 3 Database rules | ✅ n/a | No database. |
| 4 Mass assignment | ✅ | Tool arguments validated against each tool's schema (unknown or wrongly typed ones refused); card titles and tags can't inject board structure; edits of existing content need the revision they read. |
| 5 Payments | ✅ n/a | None. |
| 6 Rate limits | ✅ | Local only; scans bounded (20,000 pages, 50,000 entries per folder, 4 MB per file) and say when they're incomplete. |
| 7 Prove it | ✅ | `mcp` suite 559 passed, 0 failed; Codex clean after 10 rounds. |


### v1.0.1 — 23 November 2026 (re-check before the official release)

The official 1.0.1 is the beta's own app (`v1.0.1-beta.1`, tested by the owner, who confirmed it
works); no app file changed since the beta (`deploy.sh` refuses otherwise), only documentation.

| # | Result | Found, and what was done |
|---|---|---|
| 1 Secrets | ✅ | No token-, key- or secret-shaped strings in the repository (scan on 2026-11-23); the public repository's history is fresh and has only the noreply identity; the app is ad-hoc signed (no name or email). |
| 2 Ownership | ✅ | Unchanged since the beta's record below. |
| 3 Database rules | ✅ n/a | No database. |
| 4 Mass assignment | ✅ | Unchanged since the beta. |
| 5 Payments | ✅ n/a | None. |
| 6 Rate limits | ✅ | Unchanged since the beta. |
| 7 Prove it | ✅ | `ownership` 29 passed, 0 failed (2026-11-23). |

### v1.0.1-beta.1 — 22 November 2026 (re-check before the beta)

Branch `release/1.0.1-beta.1` (on `feature/in-app-updates`), adding in-app updates and holding back
LP's Google registration until Google approves it.

| # | Result | Found, and what was done |
|---|---|---|
| 1 Secrets | ✅ | The release key stays in the owner's Keychain (only the public half is in the code; `update.json` signed in the dry run). The Google client ID is a public identifier. No new secrets; the Release build has none of the Debug-only update switches. |
| 2 Ownership | ✅ | The update helper accepts only LP (code-signing requirement), verifies the signed manifest itself and installs only a newer LP with a valid signature. New Google sign-ins and Drive grants can't use LP's registration while it's under review. |
| 3 Database rules | ✅ n/a | No database. |
| 4 Mass assignment | ✅ | Release notes are unsigned text: links shown as text, never opened. The helper trusts nothing the app sends. |
| 5 Payments | ✅ n/a | None. |
| 6 Rate limits | ✅ | The update check runs once a day and honours GitHub's `Retry-After` / reset time; downloads are capped at the signed size. |
| 7 Prove it | ✅ | `ownership` 29 passed, 0 failed; `updates` 60 passed. Codex: 3 rounds on this branch (4 → 3 → clean). |

### v1.0.1 — 19 November 2026

Branch `feature/release-rules` (with `feature/codex-review`, `feature/privacy-and-license` and
`feature/full-calendar-sync`).

| # | Result | Found, and what was done |
|---|---|---|
| 1 Secrets | ✅ | No secret in the history or the files; every environment variable is Debug-only or a build setting; the Release build has none of the test switches; v1.0.0's published app is ad-hoc signed (no name or email). **Added:** `deploy.sh` refuses an app whose signature shows an email address or that contains a token or key, and publishes the official version as the tested beta's own file. Harness runs never read the real GitHub token. Nothing to rotate. |
| 2 Ownership | ✅ | Every way in is checked (table above). **Changed:** the decision about shared pages is one tested function, `ShareTrust`. |
| 3 Database rules | ✅ n/a | No database. Sandbox confirmed in the Release build; Keychain items stay on the Mac. |
| 4 Mass assignment | ✅ | Untrusted files can't grant permission, choose addresses, paths or link targets. No change needed. |
| 5 Payments | ✅ n/a | None; no third-party code; costs the owner nothing. |
| 6 Rate limits | ✅ fixed | **Before:** a GitHub limit was reported as "the token can't create gists" and every edit tried again; calendar limits were a generic error, tried again at the next sync. **Now:** LP recognises "slow down" from all three services (GitHub's message-only one included), sends nothing for that account or token until the time asked (at most an hour, never shortened by a later answer), retries automatic page updates at most 3 times with growing waits, and says until when. Codex's review of this point found 9 more cases over three rounds (among them a request slipping past a wait while it fetched a token, and the sign-in service's own "slow down"); all fixed, and its last pass over the whole branch found nothing. |
| 7 Prove it | ✅ | 29 checks, all passing (output below); 4 fail with the permission check removed. |
| Google Drive sharing (added to 1.0.1) | ✅ | Checked again for the new destination. **1:** no secret — each person's own Google client ID; only `drive.file`, asked for when wanted. **2/4:** a Drive page's permission names its account and file, so an edited record can't redirect it; IDs checked. **3:** the list of Drive pages LP made is in LP's preferences, used to delete them on disconnect. **6:** Drive shares the calendar's per-account "slow down" wait. **7:** 7 new ownership checks (with the account left out of the permission, one fails). With the owner's real Google account: 17 of 17 (the Doc is view-only, not searchable, holds no notes and doesn't have the owner's email or name in its page, keeps its link on update, and is gone within seconds of deleting). **Codex review:** a disconnect racing a page being made, a page adopted from another Mac, and a page whose "make it viewable" step failed could all stay online outside the clean-up list — now a page is listed from its upload on, adopted pages are listed, and a disconnect holds back new Drive work and waits for work on its way (`DriveWork`, tested; the four cases run in the harness); a failed clean-up is reported as such, with the page to open; and the docs no longer say Google hides the owner — Google may show which account owns a Doc. Round 2: an update finishing during a disconnect could keep its page off the list — a page is now listed before an update is sent (reproduced in the harness first, then fixed). Round 3: nothing left (`0bf171c`). |
| One-click Connect (added to 1.0.1; branch `feature/one-click-connect`) | ✅ | LP gets its own Google registration (the owner's decision, 2026-11-20; Microsoft's follows in the next update). **1:** the client IDs are public identifiers, not secrets — no client secret, PKCE; nothing token-shaped. A fake app could reuse them (as with any desktop app): Google/Microsoft can suspend misuse and LP can replace them (`docs/REGISTERING_LP.md`). **2/4:** unchanged — each sign-in and its data stay the person's; tokens remember which registration issued them (`OAuthTokens.clientID`), so a setting can't move an account or strand its Drive pages. **3:** nothing new stored but that client ID inside the Keychain item. **6:** one Google project's quota is now shared by every LP user (about 300 calendar requests a person a day against a default 1,000,000 a project); LP's per-account waits stay. **7:** calendar tests for the registration choice, the remembered and pinned client, and the refusal message. Codex round 1: 3 findings (another account chosen while allowing Drive could move it to another registration; 1.0.0 tokens unpinned until a refresh; the Drive warning hidden without a built-in registration) — fixed. Round 2: 2 races (a late "Allow Google Drive…" replacing a newer connection; a page still being made not counted) — fixed, the rules pure and tested (`ConnectionReplacement`). Round 3: a same-registration reconnect could end the sign-in of an upload in flight — no connection is replaced while Drive work runs through it. Round 4: nothing left (`2b80761`). **Real accounts (2026-11-20):** Google's shipped ID only (`11527194109-…`; Microsoft's stays nil, no ID of the owner's in the tree): the 1.0.1 Release build connected the support account with one click (both calendar permissions, English consent), allowed Drive (`drive.file` only), shared a board as a Doc, then disconnected, which removed the Doc — recorded for Google's review. |
| Website (added to 1.0.1) | ✅ | Static pages only (GitHub Pages, its own public repository): no scripts, forms, cookies or outside fonts; a Content Security Policy that allows only the site's own stylesheet and images. **1:** no secret or private address — the support address only; the owner's personal Search Console file removed (one verified owner). Reviewed by Codex until clean (rounds 59–61). |
| Release-readiness pass (2026-11-21, `fix/release-readiness`) | ✅ fixed | Codex's final pass over the whole v1.0.1 stack found 8 points; the code ones fixed: **2/6:** a page published while the board's `.lp` folder became unwritable stayed online with no link in LP — now it is removed again (or the page is named to delete by hand), tried in the harness with the folder made read-only mid-upload; `deploy.sh` counts a previous release as backed up only with its own non-empty `LP-<version>.zip`. Secret scan of the tree: no personal email, client ID or token. A queued update possibly dropped on leaving a board couldn't be reproduced; keeping the board alive for it let a stale copy overwrite newer settings (round 2), so it stays as reviewed before. |

| In-app updates (added to 1.0.1; `feature/in-app-updates`) | ✅ | **1 Secrets:** a new secret, the release signing key — only in the owner's login Keychain (never in the repository, a file or a log; `deploy.sh`'s secret scan still runs on every app); the app holds only its public half. **2 Ownership / 4 Mass assignment:** nothing from the network is trusted on its own — an update is installed only if update.json is signed by LP's key, consistent (LP's bundle ID, tag = version, zip named after the tag), newer, and the zip matches its size and SHA-256; the unsandboxed helper accepts only LP (code requirement), re-checks all of it itself, copies the zip before hashing (no swap between check and use), and requires the app inside to be LP at exactly that version and build with a valid code signature. A downgrade can't be offered (only newer builds), a beta never reaches someone who didn't ask for betas, and http is refused (Debug builds allow 127.0.0.1 for the end-to-end test). **6 Rate limits:** GitHub's 60 requests an hour per address — LP checks once a day; "slow down" (403/429) is reported and retried the next day. Codex round 1 (10 findings, all fixed): a symlink swap of the zip between check and copy (now one no-follow descriptor into the helper's own file), a replayed older signed release (the helper now requires newer than the installed app and a supported macOS), unbounded metadata downloads, unsigned release-note links, a restart that closed the page before it was certain, and key rotation stranding skipped versions. Round 2 (4): a cached Info.plist that could allow a downgrade, the size limit depending on the main thread, "slow down" on downloads not kept, a stale doc — fixed. Round 3 (1): an installed app without a valid build number — refused. Round 4: nothing left (`7ba738f`). **7 Prove it:** the `updates` suite (60 checks: foreign keys, one changed byte, re-encoded JSON, eleven inconsistent manifests, betas and drafts, plain http); end to end on this Mac: a sandboxed build 100 found a locally served, test-key-signed build 200, downloaded it, the helper installed it (quarantine removed, signature valid) and LP restarted on build 200. |

`LP_TEST_VERBOSE=1 Scripts/test.sh ownership`:

```
A's shared progress page (a secret gist on A's GitHub account)
  ✓ A's Mac may update and delete A's page
  ✓ B's Mac can't update A's page, nor delete it (B's copy has the record, not the permission)
  ✓ B's permission for B's own page doesn't reach A's page
  ✓ a history pointed at another of A's gists can't make A's Mac overwrite or delete that gist
  ✓ another board put into that file can't change the page
  ✓ a file without the board's ID can't change the page
  ✓ a copy in another place needs its own permission
  ✓ an ID with a path in it never reaches GitHub, even with a permission
  ✓ without a record there is nothing to change
  ✓ the page's address is always on gist.github.com
  ✓ a link written into the folder is never opened

A's shared progress page in A's own Google Drive (a Google Doc)
  ✓ A's Mac may update and delete A's Drive page
  ✓ B's copy of the folder can't update or delete it
  ✓ a history pointed at another Google account can't use A's permission
  ✓ nor one pointed at another file in A's Drive
  ✓ a permission for a gist with that ID doesn't count for a Drive page
  ✓ a file ID with a path in it never reaches Google, even with a permission
  ✓ the page's address is always on docs.google.com, built from its ID

A's sign-in to Google or Microsoft (the reply that brings A back to LP)
  ✓ the reply to the sign-in A started is accepted
  ✓ a reply to any other sign-in is refused, so a forged one can't connect B's account to A's LP
  ✓ a reply without the sign-in's mark is refused
  ✓ each sign-in has its own secret; a stolen code is useless without it

A link to LP from a web page or another app (localproductivity://)
  ✓ a link can only show a page, the calendar, the boards or Home
  ✓ a link can't delete, tick off, share or change settings: localproductivity://delete?path=Notes/Plan.md is ignored
  ✓ a link can't delete, tick off, share or change settings: localproductivity://complete?task=Ship is ignored
  ✓ a link can't delete, tick off, share or change settings: localproductivity://share?board=Launch is ignored
  ✓ a link can't delete, tick off, share or change settings: localproductivity://settings?token=x is ignored
  ✓ a link can't reach outside the workspace folder
  ✓ nor name a file by its full path
29 passed, 0 failed
```
