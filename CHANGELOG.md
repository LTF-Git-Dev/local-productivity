# Changelog

What changed in LP, newest first. Every released version is a tag and a GitHub Release with its
app; its entry here becomes the release notes, and `Scripts/rollback.sh` restores any of them.

Each working session adds a dated line under **Unreleased** — what changed, on which branch, and
whether it was released. When the owner confirms a release, those lines move under the new
version's heading (`## <version> — <date>`), which `Scripts/deploy.sh` reads.

## Unreleased

- 2026-11-23 — **Ready for the next session and for contributors:** a fresh clone of the public
  repository builds and passes all 993 tests; README's Development section says where to start
  (and its test count is current); repository topics added; LP Design (brand sources) backed up to
  the private `LTF-Git-Dev/lp-design`.

- 2026-11-23 — **Docs brought up to date** after the beta and going public: the user guide's cover
  says 1.0.1 (PDF rebuilt and re-attached to the beta's release); README tells first-time users
  how to open LP (Privacy & Security → Open Anyway); PRD current version, document dates.

- 2026-11-23 — **v1.0.1-beta.1 published** (GitHub pre-release from `release/1.0.1-beta.1`, at the
  owner's yes); checked signed-out: listed by the API, `update.json` signature valid, zip checksum
  matches.
- 2026-11-23 — **The repository is public**, at the owner's request (option C, recommended by
  Codex): a fresh history under the same name, so LP's updater and the website's links keep
  working; the old private history is kept as `local-productivity-archive` and a local bundle.
  v1.0.0's release re-created with its original files; private vulnerability reporting on.

- 2026-11-22 — **Google one-click Connect held back until Google approves LP**, at the owner's
  request (Codex agreed: an unverified app warns "unsafe" and Google allows only 100 people ever
  until it's verified). Branch `release/1.0.1-beta.1` (on `feature/in-app-updates`); not released.
  `BuiltInRegistration.googleAwaitingReview` hides LP's Google registration; Settings → Calendars
  and Sharing say it's coming soon and point to System Settings → Internet Accounts; your own
  client ID and connections made earlier keep working. Set the flag to false in the first build
  after Google approves. `MARKETING_VERSION` 1.0.1 for the beta.

- 2026-11-21 — **Update LP from inside the app**, at the owner's request. Branch
  `feature/in-app-updates` (on `fix/release-readiness`); not released.
  - LP checks its GitHub Releases once a day (Settings → General → Updates: turn it off, or
    include betas) and on **LP → Check for Updates…**. A Software Update window shows what's new
    with **Install and Restart**, **Later** and **Skip This Version**.
  - One click: LP downloads the update, its helper (**LPUpdateInstaller**, an XPC service inside
    LP.app — the sandboxed app can't replace itself) checks it and puts it in place of the old
    app, and LP restarts on the new version after saving everything as on quit.
  - Only the owner's releases are installed: every release now carries `update.json` signed with
    the release key in the owner's Keychain (`Scripts/release-key.swift`; `deploy.sh` signs and
    uploads it); the download must match it byte for byte, and the app inside must be LP at
    exactly that version and build with a valid code signature.
  - Each build has its own build number, so a newer beta of the same version is offered; the
    official release is its beta's app, so testers aren't offered what they already have.
  - Works once the repository is public (the owner's plan for after the beta); until then the
    check says LP's releases can't be found.
  - Codex's first review found 10 points, all fixed: the helper reads the download through one
    descriptor that won't follow a link and copies it into its own file (no swap between check and
    use); it refuses an update that isn't newer than the installed app or doesn't run on this
    macOS; LP no longer closes the open page before restarting (it starts the new copy, which waits
    and gives up if the old one stays, then quits the usual way); downloads stop at their expected
    size; release-note links are shown as text and the release page comes from the verified tag;
    every release is looked at, passing over ones LP can't verify (so a key can be replaced); failed
    checks wait a day too and GitHub's "slow down" time is kept; README and the website mention
    the daily check.
  - Codex's second look found 4 more, fixed: the helper reads the installed app's Info.plist from
    disk every time (macOS caches it, which could have let a second request downgrade); downloads
    stop at the signed size on URLSession's own queue, whatever the main thread is doing; GitHub's
    "slow down" on the download itself is kept too; ARCHITECTURE describes the new restart order.
  - Codex round 3: the helper also refuses an installed app without a valid build number. Round 4:
    nothing left (`7ba738f`). Codex: 4 rounds (10 → 4 → 1 → 0).
  - A clean Release build has the helper inside (not sandboxed), a valid signature and none of the
    Debug-only test switches.
  - Tested: a new `updates` suite (60 checks; 993 in all) and end to end on this Mac (build 100
    updated itself to a locally served build 200 and restarted). Privacy policy, README, user
    guide (27 pages), architecture, releasing and security checklist updated.
- 2026-11-21 — **Final review before the beta**, `fix/release-readiness`; not released. Codex's
  pass over the whole v1.0.1 stack found 8 points; 7 fixed: a board shared while its `.lp`
  folder became unwritable no longer leaves a page online that LP can't find again (it is removed,
  or named so you can delete it); `deploy.sh` accepts a previous release as backed up only with its own
  non-empty app zip; README and CODEX no longer ask one-click users to set up a Google Cloud project
  for Drive; the security record covers One-click Connect and the website; outdated notes marked.
  The eighth (an automatic update dropped if you leave a board within seconds) couldn't be
  reproduced; keeping the board alive for it let an old copy overwrite newer settings (Codex,
  round 2), so it was left as it was — the next change or Update Now brings the page up to date.
- 2026-11-21 — **Google verification submitted; demo cleaned up.** The owner recorded the demo in
  their own Mac user with the 1.0.1 Release build (LP's shipped client ID, the support account);
  Claude cut it to 81 seconds with English captions, the password entries removed and no audio,
  and the owner submitted it with the scope texts and an appeal of the brand check. Afterwards:
  the demo account had already been disconnected in LP (no accounts or Drive pages left); the
  owner's LP settings were restored from the backup (all 15 identical); the demo folder in
  /Users/Shared went to the Trash; the 1.0.1 build is now `/Applications/LP.app` (the owner's
  previous everyday copy was a 1.0.0 Xcode build with the old icon). The owner confirmed a test
  notification shows Orbit Bear. Nothing released; the beta waits for Google's approval.
- 2026-11-20 — **Old logo clean-up**, at the owner's request (a notification banner showed the old
  blue icon). The user guide's welcome screenshot also showed it: retaken with Orbit Bear, guide
  rebuilt (still 26 pages). macOS had 17 copies of LP registered, most of them old builds; 15 were
  unregistered (no files deleted), leaving the demo app and the current test build (both Orbit Bear),
  and Notification Center's icon cache was refreshed. The owner confirmed on 2026-11-21 that a new
  notification shows the bear. The old app bundles remain on disk
  and macOS can register them again; if the old icon returns, archive them (keeping rollback copies).
- 2026-11-20 — **One owner for the website**, at the owner's request: ltf.dev.supp@gmail.com stays
  the only verified owner in Google Search Console; the first owner (the owner's personal account)
  was removed there, and its verification file `google33ddc982459b7914.html` from the site.
- 2026-11-20 — **The Google demo video plan**, `docs/REGISTERING_LP.md`; confirmed with the reviewer
  Codex (its must-haves: both consent screens, the client ID in the address bar, the shared Doc
  updated as well as created and removed, no credentials on screen, a clean Google grant, a
  separate Mac user with a production-equivalent build, branding verified first). LP's plain-text
  authorization buttons stay (Google's API branding guidance asks for plain text).
- 2026-11-20 — **Search keeps pages that match partly by name**, `fix/search-mixed-matches` (on
  `feature/website-redesign`); not released. A search like "launch budget" dropped a page named
  "Launch Plan" that mentions the budget: it wasn't under "Pages" (that needs every word in the
  name) and the "In pages" list skipped anything matching the name at all. Now everything not
  already listed under "Pages" appears under "In pages" (`SearchHit.inPages`; new `search` test
  suite, 6 checks; 933 in all). Found by the reviewer Codex while checking the website's "Find
  anything" tile, which now also names ⌘P (⌘K links selected text instead).
- 2026-11-20 — **The website redesigned**, at the owner's request; `feature/website-redesign`
  (the site's own `redesign` branch until it is published). Notion's structure with LP's Apple
  finish: a navy hero with the Orbit Bear and LP's real Home window, six features with real
  screenshots in the visitor's light or dark look, "Your files stay yours", the same Google and
  Microsoft data section (every permission and what LP does with it, the Limited Use statement
  word for word, how to disconnect, links to the policies), "Get LP" and a fuller footer; policy
  pages get an "On this page" list and calmer type; a 404 page. Every text colour was measured
  (WCAG AA or better on every surface, both looks); motion only when the visitor allows it. The
  pages load nothing from other sites (no scripts, fonts or trackers: a Content Security Policy
  allows only the site's own stylesheet and images). Screenshots come from the harness with
  `Scripts/make-site-shots.sh`, cropped and compressed by `Scripts/site-image.swift` (AVIF plus a
  JPEG fallback; about 290 KB per look for the home page). Icons are Phosphor Icons (MIT, credited
  on the licence page). Checked in WebKit and Chrome at desktop, tablet and phone widths in both
  looks. The user guide now points to the website for the policies (the repository is private)
  and no longer says Google needs your own app registration (LP's own is the default since
  one-click Connect; Microsoft still needs yours). The Widgets tile became "Find anything"
  (⌘K search): released builds are signed ad hoc, so widgets need setting up first. The guide
  and Connected Accounts no longer promise a shared page always catches up by itself: when a
  service keeps asking LP to wait, the next change or Update Now does it (reviewer's finding).
  **Published** at the owner's request once the reviewer Codex was clean (rounds 59–61: 1, 2, 0
  findings): https://ltf-git-dev.github.io, site commit `40e2dfd`; checked live (pages, images,
  the Search Console files and the 404 page; no cookies).
- 2026-11-20 — **08 Orbit Bear chosen by the owner**, `feature/brand-icon`; not released.
  The owner chose **08 Orbit Bear on 20 November 2026** (Task F), replacing the earlier 07
  recommendation. Installed the full bear with headset/progress ring at 64 px and above;
  refined 16/32 masters use an enlarged head and bold headset/cheeks, without the body/ring.
  The same head forms the logo mark, LP lockup and dark variants. Added the 120 × 120 Google
  branding PNG (under 1 MB); previews mark 08 as chosen. 07 Focus Bear and 09 Desk Bear remain
  explorations. All design materials and the guarded renderer live in `../LP Design/brand/`,
  outside the code repo; watercolour/line-art archives are preserved. App/guide PNGs and the
  website's icon use 08 (the website is published with it). Claude checked it outside the
  builder's sandbox: the build, all 927 tests, `--check`, the 26 guard tests and the rebuilt guide
  (cover looked at), and saw Orbit Bear in the built app; the read-only Codex found nothing to fix.
- 2026-11-20 — **Brand renderer guards**, `feature/brand-icon`; not released. Every output is
  preflighted in one of four repository folders with symlinks resolved; symlink output files
  and invalid catalog names/mappings are refused before any replacement. Added
  `swift "../LP Design/brand/make-icon.swift" --self-test-guards`: 24 temporary-fixture cases pass with no
  writes on rejection; `--check` passes. Corrected historical build/PDF notes to record Claude's
  completed verification at `51e985b`. Artwork is unchanged.
- 2026-11-20 — **A new logo and app icon**, at the owner's request; branch `feature/brand-icon`;
  not released.
  - An ultra-minimal, black-and-white **stick-figure cat** — the owner's inspiration: playful,
    modern nursery wall art, clean and simple — drawn with one round 48-unit line, with a bolder
    master for 16/32 px, on the macOS tile. No face.
  - Alternatives in the same line style: 04 front submarine, 05 side submarine. The earlier
    watercolour submarine (the owner then asked for no face and nothing on its head) is archived
    in `../LP Design/brand/explorations/archive/`.
  - Designed by Codex (the builder) with the ui-ux-pro-max and design skills; checked by Claude
    (all 927 tests, the build, the icon in the built app, light/dark, `--check`, the rebuilt cat-cover
    guide at `51e985b`); the read-only Codex reviewed it — 5 findings, the renderer guards and the
    Microsoft wording fixed, then clean (`f0943a9`). The design document is now
    `../LP Design/brand/README.md`; the renderer lives beside it. The bear proposal above
    supersedes this cat checkpoint.
- 2026-11-20 — **One-click Connect for Google**, at the owner's request (people found
  making their own Google Cloud / Entra app registration far too much). Branch
  `feature/one-click-connect` (on top of `feature/drive-sharing`); not released — the beta
  (v1.0.1-beta.1) waits for Google's review of LP's registration.
  - LP has its own Google registration, so **Connect Google Account…** needs no setup; its client
    ID is a public identifier, not a secret (PKCE, no client secret). Microsoft follows in the next
    update (the owner's decision: Microsoft blocked creating the account for LP's registration);
    until then Outlook connects with your own client ID or through the Mac's Internet Accounts.
  - **Use Your Own Client ID** becomes an Advanced option (Google's steps now use a Personal mode
    project: only your account, no review, no warning, no 7-day limit).
  - Settings → Calendars now points to the no-registration route too: Google, Exchange and other
    accounts added in System Settings → Internet Accounts reach LP through Apple Calendar (**Add
    an Account in System Settings…**). Notes on Microsoft 365 work accounts on a Mac and on
    work/school approval.
  - A connection keeps the registration that issued its sign-in, so changing the setting never
    breaks it or strands its shared Drive pages.
  - A small public website (home page, privacy policy, terms — generated from the app's own
    policies) for Google's review: `Scripts/make-site.py`; `docs/REGISTERING_LP.md` explains the
    registrations. (Published on 2026-11-20 — see the website entries above.)
  - Codex's first look found three things, all fixed: choosing another connected account while
    allowing Drive could move that account to another registration (now any other account is
    refused before anything is saved, and Connect won't move an account whose Drive pages need its
    registration); tokens from LP 1.0.0 are now pinned to their registration on first load; and
    the warning about Drive pages shows even before LP has a registration of its own.
  - Its second look found two races, both fixed: an "Allow Google Drive…" that finished after the
    account was connected again through another registration could undo that newer connection
    (it now never moves an account to another registration, and it decides after its last wait);
    and Connect now also waits out a page still being made before moving an account.
  - Its third look found one more: reconnecting an account through the same registration while a
    board page was being uploaded ended the sign-in that upload was using; no connection is now
    replaced while Drive work runs through it ("try again in a moment"). The fourth look found
    nothing left (`2b80761`).
  - Tests: 927 checks (calendar 146).
- 2026-11-19 — **Share boards to your own Google Drive**, at the owner's request. Branch
  `feature/drive-sharing` (on top of `feature/github-sign-in`, so it holds everything below); not
  released.
  - A board's progress page can now go to your own Google Drive as a Google Doc — through the
    Google account you connected for the calendar, once you allow it (**Settings → Sharing → Allow
    Google Drive…**). LP asks Google only for the files it creates (`drive.file`). Or to GitHub, as
    before, with your own token. (At the time no registration was shared; since One-click Connect,
    above, Google goes through LP's own registration unless you set your own client ID.)
  - Anyone with the link can read the Doc without signing in; it isn't searchable; it holds no card
    notes, and LP doesn't put your name or email on it (checked with the owner's real account) —
    though Google may show viewers which Google account owns it, as the policies now say. Updates
    keep the same link. **Stop Sharing** deletes it.
  - Disconnecting a Google account deletes LP's Docs from its Drive first; if that can't be done
    (offline), LP asks before disconnecting anyway and says where they still are.
  - A Google API that isn't turned on in your Google Cloud project is now named in the message.
  - Checked with the owner's Google account: an automatic test (Debug builds only) made, viewed,
    updated and deleted a page — 17 of 17; a deleted Doc's link stops working within seconds.
  - Codex's review found five things, all fixed: a disconnect while a page was still being made
    could leave it online (disconnecting now waits for it, and nothing new starts meanwhile); a page
    kept up to date from a second Mac, or one whose "make it viewable" step failed, wasn't on the
    list disconnecting works through (both are now); a clean-up that failed was reported as done
    (now said as it is, with **Open Page**); and the docs promised more about Google hiding your
    name than Google does. "Slow down" messages no longer promise automatic updates where there
    are none. Its second look found one more: an update finishing during a disconnect could keep
    a page off the list — a page now goes on the list before an update is sent. The third look
    found nothing left (`0bf171c`).
  - Tests: 909 checks (calendar 128, boards 220, ownership 29).
- 2026-11-19 — **Connect GitHub** (a sign-in button for sharing) was built and reviewed on
  `feature/github-sign-in`, then **withdrawn** at the owner's request, before any release: it used
  one GitHub registration for everyone, whose public client ID anyone could reuse to ask people to
  approve "LP". Sharing will instead use each person's own accounts — their own Google Drive, or
  GitHub with their own token (branch `feature/drive-sharing`). Kept from it: a sign-in or token
  check that began before a connect or disconnect can't undo it, an old account's name can't show
  for a new connection, harness runs never change the real token, and **Manage the Token on
  GitHub** in Settings → Sharing.
- 2026-11-19 — **Security checklist and beta releases**, at the owner's request. Branch
  `feature/release-rules` (on top of `feature/full-calendar-sync`, so it holds everything below);
  not released.
  - New standing rules: every version is published first as a **beta** — a GitHub pre-release,
    built from its branch — for the owner to test, and becomes the official version (merged into
    `main`, marked Latest) only once the owner confirms it works; the official version must be
    exactly the beta that was tested (`Scripts/deploy.sh 1.0.1-beta.1`, later `1.0.1`). One
    repository, private until the owner says it can be public. Steps: `docs/RELEASING.md`.
  - The owner's **security checklist** — secrets, ownership, database rules, mass assignment,
    payments, rate limits, prove it — is run before every version is finalized. What each point
    means for LP, and the result for 1.0.1: `docs/SECURITY_CHECKLIST.md`.
  - Found and fixed: when GitHub said "too many requests", LP reported that the token couldn't
    create gists and tried again on every edit; Google's and Microsoft's limits showed as unclear
    errors. LP now sends nothing for that calendar account or GitHub token until the time asked (at
    most an hour) — not the next page of a sync under way, not a change — says until when, and
    catches up afterwards; automatic page updates retry at most 3 times.
  - Proven: someone else's copy of your folder, a folder handed to you, a link on a web page or a
    forged sign-in reply can't change what is yours — a new test suite, `ownership` (22 checks;
    `LP_TEST_VERBOSE=1 Scripts/test.sh ownership` prints them).
  - The release script refuses to publish an app whose signature shows an email address, or that
    contains anything shaped like a token or private key. The official version is the tested
    beta's own app file — not a new build — with its SHA-256 in the notes.
  - Codex's review: 8 findings (a draft beta passing the check, a rebuilt official app, GitHub's
    message-only limit, endless share retries, a shorter wait overwriting a longer one, a running
    sync still fetching, one token's limit blocking another, rollback's next steps), then 3 more
    (a request slipping past a wait while it fetched a token, the sign-in service's own "slow
    down", sign-ins sharing one temporary identity), then 1 (a token refresh starting late) — all
    fixed; the fourth pass over the whole branch found nothing.
  - Tests: 853 checks (calendar 117, ownership 22).
- 2026-11-19 — **Full calendar sync**, at the owner's request. Branch `feature/full-calendar-sync`
  (on top of `feature/privacy-and-license`); not released.
  - Whenever LP is online it syncs connected Google and Outlook calendars in full — from a year back
    to two years ahead, plus any other months you open — about every half hour while LP runs
    (also behind other apps), at once with the calendar's Sync button, and after every change you
    make — and keeps that copy on your Mac until you disconnect. Apple Calendar
    needs none of this: macOS keeps it all. You no longer
    need to open a month while online to have it offline. Adding, changing and deleting events
    still need a connection.
  - Refreshes in between fetch only the months shown, and never drop what was synced before.
  - Codex's review (7 rounds, the last clean) closed the races between syncing and editing: a slow
    sync can no longer bring back an event you just deleted or undo an edit, a series edit stays
    within its own calendar, and an account connected again isn't held up by the old connection.
  - Tests: 801 checks (calendar 87: the sync range, when a full sync is due, and how fetched events merge).
- 2026-11-19 — Privacy, security and licence review before releasing, at the owner's request.
  Branch `feature/privacy-and-license` (on top of `feature/codex-review`); not released.
  - **Calendar accounts ask for less.** Google: only *see your list of calendars* and *view and
    edit events* — no longer the full calendar permission, which could also change calendars and
    who they're shared with. Microsoft: calendars only, no longer your profile. LP asks Google and
    Microsoft only for the event fields it shows; attendees and organisers are never stored.
  - **Signing in asks for a private window** (with Safari as the default browser it shares and
    keeps no cookies).
  - **Disconnecting Google also ends LP's access at Google**, not only on this Mac; a sign-in right
    after waits for that to finish, and an account disconnected while it is being connected stays
    disconnected. Disconnecting also removes an account's tokens when its client ID was cleared, and
    its events from the widgets' data.
  - **Apple Calendar events are no longer copied** into LP's cache; macOS already keeps them.
  - Settings → Calendars says how LP connects (straight from your Mac, nothing through a server)
    and lists only the permissions LP needs; the share panel says the page is free, on your own
    GitHub account, and keeps earlier versions until you stop sharing.
  - **New documents:** `LICENSE` (MIT, © 2026 LTF-Git-Dev), `PRIVACY.md`, `TERMS.md`,
    `COOKIES.md`, `docs/CONNECTED_ACCOUNTS.md`, `ACCESSIBILITY.md`, `SECURITY.md`; README and the
    user guide explain privacy and sharing in plain words. The app's About window shows the copyright.
  - **Accessibility pass:** the calendar's task checkboxes and the sidebar's folder arrows have
    spoken names; search results and the block menu are buttons for VoiceOver.
  - The guide, README and docs answer two of the owner's questions: using the calendar without
    internet (events LP fetched stay viewable; changes need a connection; Apple Calendar works
    fully offline), and what a shared page's viewers can do (no account needed; they see your
    GitHub username; copies and forks can't be taken back; a separate account keeps your name off).
  - GitHub: repository description and topics updated; it stays private.
  - Tests: 790 checks (calendar 76: permissions, fields, revocation).
- 2026-11-18 — New rule from the owner: Codex reviews every finished task (through Herdr, in the
  panel to the right of Claude) and everything is tested again before a release is proposed.
  Written into `CLAUDE.md` (rule 3), `AGENTS.md` (workflow, and §7 for the reviewer), `CODEX.md`,
  `README.md` and `docs/`. Branch `feature/codex-review`; not released.
- 2026-11-18/19 — First Codex review of the whole code base, under that rule: 25 rounds, each
  finding fixed with tests, checked in the running app and sent back to Codex, ending with a
  whole-branch pass that found nothing actionable (at `774c5df`). Branch `feature/codex-review`;
  not released. What changes for people using LP:

  **Your writing is never lost or misplaced**
  - If a page can't be saved, leaving it, switching or closing the workspace, or quitting keeps
    the edits as a copy in LP's own *Recovered* folder (Application Support/LP/Recovered) and an
    alert says where (with Show in Finder) — when quitting, before LP closes. If even that fails,
    the page stays open.
  - If another app changed a page since LP read it, LP keeps that version as a copy before
    writing, and tells you. A page moved or deleted elsewhere while you edit keeps your edits as
    a copy instead of writing them back where it was.
  - A page that can't be read now says so, with Try Again, instead of opening empty — and LP
    never writes over it.
  - Back and Forward never leave a page that has nowhere to go, and skip pages that are gone.
  - Link titles with quotes, and lines like `    ~~~` inside code blocks, survive saving.
  - Pasting Markdown that starts with front matter keeps it, as a YAML code block.

  **Boards**
  - A board that can't be read (or isn't UTF-8 text) is shown as such and never changed.
  - Every change first takes in edits made elsewhere, and is written before anything else is
    updated; if writing fails, nothing changes and LP says why. Undo after an outside change no
    longer brings back an older board.
  - Moving cards to a list deleted elsewhere no longer deletes them; the card sheet saves only
    what you changed, on the card as it is now — notes changed in Obsidian while it was open are
    kept — and stays open with your typing if it can't save, archive or delete.
  - If another app replaces an open board's file with a different board, LP takes it as that
    board — with its own history and sharing — and an open card sheet won't save or delete
    anything on it.
  - Copies of a board — duplicated in LP, or copied in Finder or Obsidian — get their own
    identity, so their cards never reach the original's history or shared page. Renaming or
    moving a board in LP keeps its history and sharing; moved in Finder or Obsidian, a board that
    carries its ID keeps its history, and its shared page asks once to be kept up to date again.
  - Before LP moves a board it records the board's ID in its file (only that line changes); if
    it can't, can't look inside a folder being moved, or can't update the board's history — or a
    board changes in another app while LP gets it ready — nothing is moved and LP explains.
  - Boards saved as `.markdown` open as boards; every part of LP now agrees on which files are
    boards (`---` front matter naming the Kanban plugin in the first 1 KB).

  **Sharing**
  - Sharing acts only on the board you were looking at: if another app replaced its file just
    before, nothing is shared or allowed.
  - LP only updates shared pages this Mac published. A shared page recorded in the folder by
    another Mac (or whoever the folder came from) is shown as *set up elsewhere*, with **Keep It
    Updated From Here** and **Forget It** (and, if GitHub isn't connected yet, says so). Pages
    shared from LP 1.0.0 need that one-time **Keep It Updated From Here**.
  - Shared-page links always point at GitHub; turning automatic updates off cancels a queued
    update, and nothing more is sent while Stop Sharing is deleting the page.

  **Tasks, reminders, calendar**
  - Ticking a task from Home, the calendar or a reminder changes exactly that line — matched by
    wording, date and time — and leaves it alone if it changed elsewhere or is ambiguous; if the
    file can't be written, LP says so and the task stays where it was. Reminders only act in the
    workspace they came from, and a card's reminder only on its own board.
  - Looking at far-away months no longer drops today's events from reminders and widgets;
    disconnecting a calendar account mid-refresh — or while an event change is on its way — keeps
    it disconnected, even after reconnecting it; months browsed during a slow refresh are fetched.
  - The calendar's month name no longer breaks mid-word ("Novembe / r") in a narrow window.

  **Files**
  - New pages, folders, attachments and moves can't leave the workspace through a folder that
    is a link elsewhere.

  Tests: 777 checks in seven suites (a new `tasks` suite).

## 1.0.1

### New
- **Update LP from inside the app.** LP checks for a new version once a day (Settings → General →
  Updates) or when you choose **LP → Check for Updates…**, then installs it and restarts with one
  click. Only updates signed by LP's maker are installed.
- **Share a board to your own Google Drive** as a Google Doc anyone with its link can read. LP can
  see only the Docs it creates or that you let this Mac keep up to date. In this beta it needs a
  direct Google connection with your own client ID, with the Google Drive API turned on in its
  Google Cloud project (Settings → Calendars → Use Your Own Client ID).
- **Google and Outlook calendars sync in full**, from a year ago to two years ahead, about every
  half hour while LP runs.
- **A new icon:** the Orbit Bear.

### Coming soon
- One-click **Connect Google Account…**: Google is still reviewing LP. Until then, add your Google
  account in System Settings → Internet Accounts to see its calendars through Apple Calendar, or use
  your own client ID (Settings → Calendars → Use Your Own Client ID).

### Better
- LP asks Google and Microsoft for less: for Google, your list of calendars and their events, not
  the right to change who they're shared with; for Outlook, your calendars, not your profile. LP
  uses it only to show your calendars and change events you edit. Disconnecting removes the
  sign-in and events LP kept on your Mac and asks Google to end LP's access (to be sure, and for
  Microsoft, also remove LP in your account's list of connected apps). Docs you shared are deleted
  first, unless you choose Disconnect Anyway.
- When Google, Microsoft or GitHub says "slow down", LP waits as asked.
- ⌘K search keeps pages whose name only partly matches.
- Many fixes from a full code review: no lost edits when you leave a page, safer board sharing,
  reminders and tasks.
- LP is open source under the MIT License, with a privacy policy, terms and an accessibility
  statement.

## 1.0.0 — 2026-11-18

The first release of LP: a calm, native macOS home for your notes, tasks, calendar and projects,
built on a folder of plain Markdown files. For macOS 15 Sequoia and later, on Apple silicon and
Intel. New to LP? Start with the user guide attached to this release (also in the repository as
`docs/LP User Guide.pdf`).

**Notes**
- Any folder is a workspace — an Obsidian vault works as it is.
- Write without seeing Markdown: headings, lists, to-dos, quotes, callouts, code, tables, dividers
  and images look finished while you type. `/` opens the block menu, `[[` links a page, a
  formatting bar appears over a selection, and every block has a handle to move or change it.
- To-dos with due dates and times (`📅 2026-11-20 14:30`), shown as chips coloured by urgency.
- Your files stay exactly as they were unless you edit them, and changes made in other apps show
  up straight away.

**Finding your way**
- Home with quick actions, recent pages and every open task; search (⌘K); today's note (⌘T);
  favourites; folders you can rename, move, duplicate and trash.

**Calendar**
- A month view with your daily notes and due tasks, in two-way sync with Apple Calendar, Google
  Calendar and Microsoft Outlook. Add, change and delete events, including repeating ones.

**Boards**
- Trello-style boards — one per project — stored as Obsidian Kanban files, with an overview of
  every board and templates for new ones.
- Drag cards or move them from the keyboard; card details with due dates, reminder times, tags and
  checklists; undo for every change.
- Progress tracking with a full history, shared as a live read-only page anyone with the link can
  open, or exported as a report.

**Reminders and widgets**
- Reminders when tasks and cards are due (at their own time), alerts before events and a morning
  summary — even when LP is closed — with Mark as Done and snooze buttons.
- Today and Board widgets for the desktop (they need LP signed with your Apple ID team once; the
  guide explains how).

**Make it yours**
- Text size from 12 to 24 points, line spacing, page width, typeface and interface size; light
  and dark.

**Quality**
- Sandboxed and hardened; nothing in a note can reach outside your workspace or run code.
- Quick with large workspaces: in a 3,000-note workspace pages open in under 100 ms and search
  takes about 25 ms.
- 681 automated checks, including fuzzing thousands of notes and boards for lost text.

## Before 1.0.0

On 17 and 18 November 2026, test builds were published as 1.0.0 and 1.1.0. They were withdrawn on
18 November, when LP was released afresh as 1.0.0. Their code is still in the history — the old
1.0.0 at `b25bae0`, the old 1.1.0 at `7a2ed22` — and their apps are kept outside the repository.
