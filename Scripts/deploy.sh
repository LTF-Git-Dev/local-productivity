#!/bin/zsh
# Releases a new version of LP: first as a beta the owner tests, then — once they have confirmed the
# beta works — as the official version. The version it replaces is always backed up first, so it can
# be restored with Scripts/rollback.sh.
#
#   Scripts/deploy.sh 1.1.0-beta.1 --dry-run     every check and build; nothing is tagged, pushed or published
#   Scripts/deploy.sh 1.1.0-beta.1 --confirmed   a beta: a GitHub pre-release built from the release branch
#                                                (main is not touched), for the owner to test
#   Scripts/deploy.sh 1.1.0 --confirmed          the official version, from main, marked Latest — only after
#                                                the owner confirmed the beta and its branch was merged. Its
#                                                app is the beta's own app (the same file), not a new build
#   (Run by hand without --confirmed, the script asks you to type the version instead.)
#   --allow-signer-email                         publish even though the app's signature shows an email
#                                                address — only if the owner agreed to that
#
# The owner's rules: no version is released unless they have confirmed it; every version is a beta
# first; the official version is exactly the code the owner tested as its newest beta. Run by an agent
# (no terminal), the script needs --confirmed, which an agent passes only after the owner said yes to
# this release.
#
# Steps, stopping at the first problem:
#   1. Checks   nothing uncommitted, the tag is new, MARKETING_VERSION matches. A beta: on its release
#               branch (not main), pushed. Official: on main, in step with origin, the newest beta of
#               this version published (not a draft) with its app, and no app file changed since it.
#   2. Tests    Scripts/test.sh and a sandboxed build.
#   3. Backup   the official release being replaced (the newest vX.Y.Z tag) must be published on GitHub
#               with its app. If it is not, it is built from its tag and published now.
#   4. App      a beta: a Release build, zipped to .build/releases/LP-<version>.zip. Official: the
#               beta's zip, downloaded from its release. Either is refused if its signature shows an
#               email address or it contains anything that looks like a token or key.
#   4b. Update  update.json (the app's version, build, size and SHA-256) signed with the release key
#               in the owner's Keychain (Scripts/release-key.swift) as update.json.sig — what LP's
#               in-app updater checks before it offers or installs a version.
#   5. Publish  tag v<version> and push it (the official version together with main), and create the
#               GitHub Release with the app and the user guide: a pre-release for a beta, Latest for the
#               official version. The notes are the version's entry in CHANGELOG.md.

set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

VERSION="${1:-}"
DRY_RUN=0
CONFIRMED=0
ALLOW_SIGNER_EMAIL=0
for argument in "${@:2}"; do
  case "$argument" in
    --dry-run) DRY_RUN=1 ;;
    --confirmed) CONFIRMED=1 ;;
    --allow-signer-email) ALLOW_SIGNER_EMAIL=1 ;;
    *) echo "Unknown option: $argument"; exit 2 ;;
  esac
done
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$' ]]; then
  echo "Usage: Scripts/deploy.sh <major.minor.patch>[-beta.<n>] [--dry-run | --confirmed] [--allow-signer-email]"
  exit 2
fi
BASE="${VERSION%%-*}"
IS_BETA=0
[[ "$VERSION" != "$BASE" ]] && IS_BETA=1
TAG="v$VERSION"

step() { print -P "%B==> $1%b"; }
fail() { print -P "%F{red}✗ $1%f"; exit 1; }

# The app's files: what has to be exactly what the owner tested.
APP_PATHS=("Local Productivity" LPWidgets Shared UpdateCore LPUpdateInstaller "Local Productivity.xcodeproj"
           "Local Productivity.entitlements" LPWidgetsExtension.entitlements Local-Productivity-Info.plist)
# Each build gets its own build number (UTC minutes), so a newer beta of the same version is newer to
# LP's updater; the official version is the beta's app, so it keeps that beta's number.
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)
# Things that must never be inside a published app: tokens and private keys.
SECRET_PATTERN='ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{60,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abp]-[0-9A-Za-z-]{10,}|sk_live_[0-9A-Za-z]{20,}'

step "1. Checks"
BRANCH="$(git branch --show-current)"
[[ -z "$(git status --porcelain)" ]] || fail "There are uncommitted changes."
git fetch -q origin --tags
if (( IS_BETA )); then
  [[ -n "$BRANCH" && "$BRANCH" != "main" ]] \
    || fail "Publish a beta from its release branch, not from main: main gets a version only once its beta is confirmed."
  git rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null || fail "Push $BRANCH to origin first."
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH")" ]] || fail "$BRANCH is not in step with origin/$BRANCH. Push or pull first."
else
  [[ "$BRANCH" == "main" ]] || fail "Release from main. Merge the branch of the confirmed beta into main first."
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not in step with origin/main. Push or pull first."
  BETA=$( (git tag --list "v$BASE-beta.*" | sort -V | tail -1) || true )
  [[ -n "$BETA" ]] || fail "There is no beta of $BASE. Publish one for the owner to test first: Scripts/deploy.sh $BASE-beta.1"
  BETA_ZIP="LP-${BETA#v}.zip"
  # Published as a pre-release with its app uploaded — not a draft left by an interrupted upload.
  gh release view "$BETA" --json isDraft,isPrerelease,assets --jq "select(.isDraft == false and .isPrerelease == true) | .assets[] | select(.name == \"$BETA_ZIP\" and .size > 0 and .state == \"uploaded\") | .name" 2>/dev/null \
    | grep -qxF "$BETA_ZIP" || fail "$BETA is not a published beta with its app ($BETA_ZIP). Publish the beta properly first."
  # What becomes official is what the owner tested.
  git diff --quiet "$BETA" HEAD -- "${APP_PATHS[@]}" || fail "The app changed since $BETA was tested. Publish another beta first."
  echo "The app is exactly $BETA, the beta the owner tested."
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "$TAG already exists."; fi
PROJECT_VERSION=$(grep -o '"MARKETING_VERSION": "[^"]*"' "Local Productivity.xcodeproj/project.xcproj" | head -1 | cut -d'"' -f4)
[[ "$PROJECT_VERSION" == "$BASE" ]] || fail "The project's MARKETING_VERSION is $PROJECT_VERSION. Set it to $BASE first."
command -v gh >/dev/null || fail "Install the GitHub CLI: brew install gh"
# The release key must be the one LP trusts, or installed copies would refuse this update.
RELEASE_KEY=$(swift Scripts/release-key.swift public 2>/dev/null || true)
[[ -n "$RELEASE_KEY" ]] || fail "There is no release key in this Mac's Keychain (swift Scripts/release-key.swift create — or restore the backup)."
grep -qF "\"$RELEASE_KEY\"" UpdateCore/UpdateCore.swift || fail "The release key in the Keychain isn't one LP trusts (UpdateFeed.publicKeys)."

gh auth status >/dev/null 2>&1 || fail "Sign in to GitHub first: gh auth login"
if (( IS_BETA )); then
  echo "Publishing $TAG, a beta for testing, from $BRANCH at $(git rev-parse --short HEAD)."
else
  echo "Releasing $TAG, the official version, from main at $(git rev-parse --short HEAD)."
fi

# Nothing outward-facing happens without the owner's go-ahead.
if (( ! DRY_RUN && ! CONFIRMED )); then
  if [[ -t 0 ]]; then
    read "typed?Type $VERSION to publish it to GitHub (anything else stops): "
    [[ "$typed" == "$VERSION" ]] || fail "Not published."
  else
    fail "Releases need the owner's confirmation. Ask them first, then run with --confirmed."
  fi
fi

step "2. Tests and build"
Scripts/test.sh || fail "Tests failed."
Scripts/build.sh | tail -1 | grep -q "BUILD SUCCEEDED" || fail "The build failed."

# What anyone who downloads the app can see in it.
check_published_app() {
  local app="$1" version="$2" signer
  signer=$( (codesign -dvv "$app" 2>&1 | grep -m1 '^Authority=' | cut -d= -f2-) || true )
  echo "Signed: ${signer:-ad hoc (no certificate, so no name or email in it)}"
  if [[ "$signer" == *@* ]] && (( ! ALLOW_SIGNER_EMAIL )); then
    fail "The $version app is signed with a certificate that shows an email address, which anyone who downloads it can read. Build without LP_TEAM_ID, or run with --allow-signer-email once the owner has agreed."
  fi
  if grep -rEaq "$SECRET_PATTERN" "$app"; then
    fail "The $version app contains something that looks like a token or a private key. Find it with: grep -rEao '$SECRET_PATTERN' \"$app\""
  fi
}

# Builds the app in <source dir> as <version> and zips it to <zip path>.
build_release() {
  local src="$1" version="$2" zip="$3" derived="$ROOT/.build/DerivedDataRelease-$2"
  # LP_TEAM_ID signs with your Apple ID team, which the widgets need to show your data.
  local team=()
  [[ -n "${LP_TEAM_ID:-}" ]] && team=(DEVELOPMENT_TEAM="$LP_TEAM_ID" -allowProvisioningUpdates)
  # The app's version is the plain number; "beta" is in the tag, the release and the zip's name.
  xcodebuild -project "$src/Local Productivity.xcodeproj" -scheme "Local Productivity" -configuration Release \
    -derivedDataPath "$derived" MARKETING_VERSION="${version%%-*}" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${team[@]}" build 2>&1 \
    | grep -E "error:|\*\* BUILD (SUCCEEDED|FAILED)" | tail -3
  local app
  app=$(find "$derived/Build/Products/Release" -maxdepth 1 -name "*.app" | head -1)
  [[ -n "$app" ]] || fail "No app was built for $version."
  check_published_app "$app" "$version"
  mkdir -p "${zip:h}"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
}

step "3. Back up the release being replaced"
# The newest official version (betas aren't what a new version replaces).
PREVIOUS=$( (git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1) || true )
if [[ -z "$PREVIOUS" ]]; then
  echo "There is no earlier release to back up."
elif gh release view "$PREVIOUS" --json isDraft,assets --jq "select(.isDraft == false) | .assets[] | select(.name == \"LP-${PREVIOUS#v}.zip\" and .size > 0 and .state == \"uploaded\") | .name" 2>/dev/null | grep -qx "LP-${PREVIOUS#v}.zip"; then
  # Only the app's own zip, uploaded and not empty, is a backup rollback can restore.
  echo "$PREVIOUS is backed up: $(gh release view "$PREVIOUS" --json url --jq .url)"
elif [[ "$(gh release view "$PREVIOUS" --json isDraft --jq .isDraft 2>/dev/null)" == "true" ]]; then
  fail "$PREVIOUS is a draft on GitHub, so it isn't a backup anyone can download. Publish or fix it first."
else
  echo "$PREVIOUS has no published app yet. Building it from its tag."
  BACKUP_SRC="$ROOT/.build/backup-src"
  git worktree remove --force "$BACKUP_SRC" 2>/dev/null || rm -rf "$BACKUP_SRC"
  git worktree add -q --detach "$BACKUP_SRC" "$PREVIOUS"
  BACKUP_ZIP="$ROOT/.build/releases/LP-${PREVIOUS#v}.zip"
  build_release "$BACKUP_SRC" "${PREVIOUS#v}" "$BACKUP_ZIP"
  git worktree remove --force "$BACKUP_SRC"
  if (( DRY_RUN )); then
    echo "(dry run) Would publish $PREVIOUS with ${BACKUP_ZIP:t}."
  elif gh release view "$PREVIOUS" >/dev/null 2>&1; then
    gh release upload "$PREVIOUS" "$BACKUP_ZIP"
  else
    gh release create "$PREVIOUS" "$BACKUP_ZIP" --title "LP ${PREVIOUS#v}" \
      --notes "Backup of ${PREVIOUS}, published before releasing ${TAG}."
  fi
fi

ZIP="$ROOT/.build/releases/LP-$VERSION.zip"
if (( IS_BETA )); then
  step "4. Release build of $TAG"
  build_release "$ROOT" "$VERSION" "$ZIP"
  echo "Built ${ZIP#$ROOT/} ($(du -h "$ZIP" | cut -f1 | tr -d ' '))."
else
  step "4. The app the owner tested: $BETA's"
  # The official version is the beta's app itself, not a new build of the same code: signing,
  # LP_TEAM_ID or the toolchain could otherwise make it differ from what was tested.
  PROMOTE="$ROOT/.build/releases/promote-$VERSION"
  rm -rf "$PROMOTE"
  mkdir -p "$PROMOTE/app"
  gh release download "$BETA" --pattern "$BETA_ZIP" --dir "$PROMOTE" || fail "Couldn't download $BETA_ZIP."
  ditto -x -k "$PROMOTE/$BETA_ZIP" "$PROMOTE/app"
  APP=$(find "$PROMOTE/app" -maxdepth 1 -name "*.app" | head -1)
  [[ -n "$APP" ]] || fail "$BETA_ZIP has no app in it."
  APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)
  [[ "$APP_VERSION" == "$BASE" ]] || fail "$BETA's app says version ${APP_VERSION:-unknown}, not $BASE."
  check_published_app "$APP" "$VERSION"
  mkdir -p "${ZIP:h}"
  cp "$PROMOTE/$BETA_ZIP" "$ZIP"
  echo "Took $BETA_ZIP from $BETA as ${ZIP:t} (the same file)."
fi
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "SHA-256: $SHA"

step "4b. Signed update file"
UPDATE_DIR="$ROOT/.build/releases/update-$VERSION"
rm -rf "$UPDATE_DIR"
mkdir -p "$UPDATE_DIR/app"
ditto -x -k "$ZIP" "$UPDATE_DIR/app"
INFO="$UPDATE_DIR/app/LP.app/Contents/Info.plist"
[[ -f "$INFO" ]] || fail "${ZIP:t} doesn't contain LP.app."
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO" 2>/dev/null || true; }
[[ "$(plist CFBundleIdentifier)" == "LTF.Local-Productivity" ]] || fail "The app in ${ZIP:t} isn't LP."
[[ "$(plist CFBundleShortVersionString)" == "$BASE" ]] || fail "The app in ${ZIP:t} isn't version $BASE."
[[ -d "$UPDATE_DIR/app/LP.app/Contents/XPCServices/LPUpdateInstaller.xpc" ]] || fail "The app has no update helper."
MANIFEST="$UPDATE_DIR/update.json"
python3 -I - "$MANIFEST" "$TAG" "$BASE" "$(plist CFBundleVersion)" "$IS_BETA" "${ZIP:t}" "$(stat -f %z "$ZIP")" "$SHA" "$(plist LSMinimumSystemVersion)" <<'PY'
import json, sys
out, tag, version, build, beta, zip_name, size, sha, minimum = sys.argv[1:]
manifest = {"schema": 1, "bundleID": "LTF.Local-Productivity", "tag": tag, "version": version, "build": build,
            "prerelease": beta == "1", "zip": zip_name, "size": int(size), "sha256": sha, "minimumSystem": minimum or "15.0"}
open(out, "w").write(json.dumps(manifest, sort_keys=True, separators=(",", ":")))
PY
swift Scripts/release-key.swift sign "$MANIFEST" || fail "Couldn't sign update.json."
swift Scripts/release-key.swift verify "$MANIFEST" >/dev/null || fail "update.json's signature doesn't check out."
rm -rf "$UPDATE_DIR/app"
echo "update.json: $(cat "$MANIFEST")"

step "5. Publish"
# The notes are the version's "## <version>" entry in CHANGELOG.md (a beta uses its version's entry),
# or else the commit list.
NOTES=$(awk -v version="$BASE" '/^## / { if (found) exit; found = ($2 == version); next } found' CHANGELOG.md 2>/dev/null || true)
if [[ -z "${NOTES//[[:space:]]/}" ]]; then
  NOTES=$(git log --no-merges --pretty='- %s' "${PREVIOUS:+$PREVIOUS..}HEAD")
fi
if (( IS_BETA )); then
  TITLE="LP $BASE beta ${VERSION##*.}"
  NOTES="**Beta, for testing.** This is not the official release yet: it becomes LP $BASE once the owner has tested it and confirmed it works. The official version stays ${PREVIOUS:-the previous release} until then."$'\n\n'"$NOTES"
  NOTES+=$'\n\n'"SHA-256 of ${ZIP:t}: \`$SHA\`"
else
  TITLE="LP $VERSION"
  NOTES+=$'\n\n'"The app is the one the owner tested as ${BETA#v} — the same file. SHA-256 of ${ZIP:t}: \`$SHA\`"
fi
if [[ -n "$PREVIOUS" ]]; then
  NOTES+=$'\n\n'"If this release has a problem: Scripts/rollback.sh ${PREVIOUS#v}"
fi
ASSETS=("$ZIP" "$MANIFEST" "$MANIFEST.sig")
GUIDE="docs/LP User Guide.pdf"
if [[ -f "$GUIDE" ]]; then
  ASSETS+=("$GUIDE#LP User Guide (PDF)")
fi
if (( DRY_RUN )); then
  if (( IS_BETA )); then
    echo "(dry run) Would tag $TAG on $BRANCH, push them, and publish \"$TITLE\" as a pre-release (not Latest) with ${ZIP:t}${GUIDE:+ and the user guide} and these notes:"
  else
    echo "(dry run) Would tag $TAG, push main and $TAG, and publish \"$TITLE\" as Latest with ${ZIP:t} (the app of $BETA)${GUIDE:+ and the user guide} and these notes:"
  fi
  echo "$NOTES"
  exit 0
fi
git tag -a "$TAG" -m "LP $VERSION"
if (( IS_BETA )); then
  git push -q origin "$BRANCH" "$TAG"
  gh release create "$TAG" "${ASSETS[@]}" --verify-tag --title "$TITLE" --notes "$NOTES" --prerelease --latest=false
  print -P "%F{green}✓ Published the beta $TAG%f for testing: $(gh release view "$TAG" --json url --jq .url)"
else
  git push -q origin main "$TAG"
  gh release create "$TAG" "${ASSETS[@]}" --verify-tag --title "$TITLE" --notes "$NOTES" --latest
  print -P "%F{green}✓ Released $TAG%f: $(gh release view "$TAG" --json url --jq .url)"
fi
