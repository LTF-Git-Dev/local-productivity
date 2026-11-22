# Releasing LP

*The owner's rules (18 and 19 November 2026). They outrank anything else in this repository.*

Every version of LP goes out **as a beta first**, for the owner (and anyone helping test) to try.
It becomes the **official version** only after the owner has tested it and confirmed it works.
Nothing is merged into `main`, tagged or published — beta or official — without the owner's yes,
and that yes covers one step only: a yes to a beta is not a yes to the official release.

There is one repository. It stays **private** until the owner says it can be public.

## The steps

1. **Work on a branch.** Every change goes on its own branch off `main` (`feature/…`, `fix/…`,
   `docs/…`), committed in coherent steps and pushed to `origin` as a backup.
2. **Finish it properly.** Tests (`Scripts/test.sh`, 0 failed), builds (`Scripts/build.sh`, a
   clean Release build), the interface in light, dark and a narrow window, a clean review by Codex
   (`AGENTS.md` §7), the **security checklist** with its result recorded
   (`docs/SECURITY_CHECKLIST.md`), and every document brought up to date.
3. **Ask for the beta.** "Ready for v1.1.0-beta.1 — shall I publish it as a beta for you to test?"
   Then wait.
4. **Publish the beta** — only after a yes:
   - set `MARKETING_VERSION` to the version (project level; the plain number, e.g. `1.1.0`);
   - turn the **Unreleased** lines of `CHANGELOG.md` into the version's entry
     (`## 1.1.0 — <date>`): it becomes the release notes;
   - commit and push the branch, then

   ```sh
   Scripts/deploy.sh 1.1.0-beta.1 --dry-run     # every check and build, nothing published
   Scripts/deploy.sh 1.1.0-beta.1 --confirmed
   ```

   This publishes a GitHub **pre-release** — never marked Latest — built from the branch, with the
   app and the user guide. `main` and the official version are untouched.
5. **Test the beta.** The owner downloads it from the Releases page (or
   `Scripts/rollback.sh 1.1.0-beta.1`, which downloads any release). If something is wrong: fix it
   on the branch, review and test again, and publish `1.1.0-beta.2` — again only after a yes.
6. **Make it official** — only after the owner confirms the beta works:

   ```sh
   git switch main && git merge --ff-only <branch> && git push origin main
   Scripts/deploy.sh 1.1.0 --dry-run
   Scripts/deploy.sh 1.1.0 --confirmed
   ```

   This publishes the official version, marked **Latest** — with **the beta's own app**: the zip
   the owner tested, downloaded from the beta's release and checked again, not a new build (both
   releases' notes give its SHA-256). `deploy.sh` refuses unless the newest beta of that version is
   published (not a draft) with its app, and no app file changed since it. (`CHANGELOG.md` and the
   other documents may still change.)

## What `deploy.sh` checks

| Check | Beta | Official |
|---|---|---|
| The owner confirmed (`--confirmed`, or the version typed in a terminal) | ✓ | ✓ |
| Nothing uncommitted; the tag is new; `MARKETING_VERSION` is the version | ✓ | ✓ |
| Branch | its release branch (not `main`), pushed and in step | `main`, in step with `origin` |
| The newest beta of this version published (not a draft) with its app, and no app file changed since it | — | ✓ |
| All tests and a sandboxed build | ✓ | ✓ |
| The official version being replaced is on GitHub with its app (built and published now if not; a draft stops it) | ✓ | ✓ |
| The app: a new Release build | ✓ | — |
| The app: the beta's own zip, its version checked | — | ✓ |
| The app's signature shows no email address; nothing in it looks like a token or private key | ✓ | ✓ |
| The release key is in this Mac's Keychain and is one LP trusts; `update.json` is written from the zip's own app (with the update helper inside), signed and verified | ✓ | ✓ |

A build signed with a certificate (`LP_TEAM_ID`, which the widgets need) shows the certificate's
name in its signature — for a free Apple ID that is often the Apple ID's email address. `deploy.sh`
stops then; `--allow-signer-email` publishes anyway, only if the owner agreed.

## The release key (in-app updates)

LP installs an update only if the release's `update.json` is signed with the **release key**.
It lives in the owner's login Keychain as "LP release signing key" (made once with
`swift Scripts/release-key.swift create`; `public` prints its public half, which is in
`UpdateFeed.publicKeys`). **Back it up:** in Keychain Access, open the item, show its password
and keep that text in a password manager. If it is lost, installed copies can't be updated by LP
any more — people download the next version by hand, and that version lists a new key. To
replace a key, add the new public key to `UpdateFeed.publicKeys` in one version, sign with the
new key from the next. Never put the private key in the repository or a file.

Before the repository is public, the update check can't read the releases (GitHub answers "not
found") and says so; nothing else is affected.

## The way back

- Every release is a tag plus a GitHub Release with the app zip; none is ever deleted unless the
  owner asks for exactly that.
- `Scripts/rollback.sh` lists the releases; `Scripts/rollback.sh 1.0.0` downloads that app;
  `Scripts/rollback.sh 1.0.0 --source` puts that version's code on a `rollback/to-v1.0.0` branch (one
  commit on top of `main`, history kept), to release like any other change — beta first.
- Never force-push, rewrite published history, or delete tags or releases unless the owner asks for
  exactly that.

## Before the repository goes public

**Done on 2026-11-23** (option C, agreed with the owner and Codex): the private repository was
renamed `local-productivity-archive` (kept private, history intact, plus a git bundle in
`../Release backups/Before going public 2026-11-23/`); a new public repository took the original
name with two commits — `LP 1.0.0` (tag `v1.0.0`, its release re-created with the original zip and
guide) and `LP 1.0.1-beta.1` — both as the noreply identity; private vulnerability reporting is on.
The list below is what was checked.

Only when the owner says so — and first, with them:

- **Commit history:** every commit shows its author's name and email address. Since 20 November
  2026 (the owner's decision) this repository commits as `LTF-Git-Dev
  <264965380+LTF-Git-Dev@users.noreply.github.com>`, GitHub's noreply address (repository-local
  `git config`); the website and LP Design do the same. Older commits still carry the owner's
  personal address: rewriting that history needs a force-push and is made only on the owner's
  explicit request, before going public. On GitHub, also turn on Settings → Emails → "Keep my email
  addresses private" and "Block command line pushes that expose my email".
- **Releases:** they become public too. Check that none has an app whose signature shows a personal
  email address (`codesign -dvv` on the app; every release so far is ad-hoc signed, which shows
  none).
- **The security checklist:** run it once more (`docs/SECURITY_CHECKLIST.md`).
- Turn on private vulnerability reporting (Settings → Code security), as `SECURITY.md` promises.
