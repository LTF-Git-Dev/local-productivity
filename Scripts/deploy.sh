#!/bin/zsh
# Releases a new version of LP — and makes sure the version it replaces is backed up first, so it
# can always be restored with Scripts/rollback.sh.
#
#   Scripts/deploy.sh 1.1.0 --dry-run     every check and build; nothing is tagged, pushed or published
#   Scripts/deploy.sh 1.1.0               release v1.1.0 from main (asks you to type the version)
#   Scripts/deploy.sh 1.1.0 --confirmed   release without asking — only once the owner has confirmed
#
# The owner's rule: no version is released unless they have confirmed it. Run by hand, the script
# asks for the version to be typed; run by an agent (no terminal), it needs --confirmed, which an
# agent passes only after the owner said yes to this release.
#
# Steps, stopping at the first problem:
#   1. Checks   on main, nothing uncommitted, in step with origin, the tag is new, and the version
#               matches MARKETING_VERSION in the project.
#   2. Tests    Scripts/test.sh and a sandboxed build.
#   3. Backup   the release being replaced (the newest v* tag) must be published on GitHub with its
#               app. If it is not, it is built from its tag and published now.
#   4. Build    a Release build of the new version, zipped to .build/releases/LP-<version>.zip.
#   5. Publish  tag v<version>, push main and the tag, and create the GitHub Release with the app
#               and the user guide. The release notes are the version's entry in CHANGELOG.md.

set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

VERSION="${1:-}"
DRY_RUN=0
CONFIRMED=0
for argument in "${@:2}"; do
  case "$argument" in
    --dry-run) DRY_RUN=1 ;;
    --confirmed) CONFIRMED=1 ;;
    *) echo "Unknown option: $argument"; exit 2 ;;
  esac
done
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Usage: Scripts/deploy.sh <major.minor.patch> [--dry-run | --confirmed]"
  exit 2
fi
TAG="v$VERSION"

step() { print -P "%B==> $1%b"; }
fail() { print -P "%F{red}✗ $1%f"; exit 1; }

step "1. Checks"
[[ "$(git branch --show-current)" == "main" ]] || fail "Release from main. Merge your branch into main first."
[[ -z "$(git status --porcelain)" ]] || fail "There are uncommitted changes."
git fetch -q origin --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not in step with origin/main. Push or pull first."
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "$TAG already exists."; fi
PROJECT_VERSION=$(grep -o '"MARKETING_VERSION": "[^"]*"' "Local Productivity.xcodeproj/project.xcproj" | head -1 | cut -d'"' -f4)
[[ "$PROJECT_VERSION" == "$VERSION" ]] || fail "The project's MARKETING_VERSION is $PROJECT_VERSION. Set it to $VERSION first."
command -v gh >/dev/null || fail "Install the GitHub CLI: brew install gh"
gh auth status >/dev/null 2>&1 || fail "Sign in to GitHub first: gh auth login"
echo "Releasing $TAG from $(git rev-parse --short HEAD)."

# Nothing outward-facing happens without the owner's go-ahead.
if (( ! DRY_RUN && ! CONFIRMED )); then
  if [[ -t 0 ]]; then
    read "typed?Type $VERSION to release it to GitHub (anything else stops): "
    [[ "$typed" == "$VERSION" ]] || fail "Not released."
  else
    fail "Releases need the owner's confirmation. Ask them first, then run with --confirmed."
  fi
fi

step "2. Tests and build"
Scripts/test.sh || fail "Tests failed."
Scripts/build.sh | tail -1 | grep -q "BUILD SUCCEEDED" || fail "The build failed."

# Builds the app in <source dir> as <version> and zips it to <zip path>.
build_release() {
  local src="$1" version="$2" zip="$3" derived="$ROOT/.build/DerivedDataRelease-$2"
  # LP_TEAM_ID signs with your Apple ID team, which the widgets need to show your data.
  local team=()
  [[ -n "${LP_TEAM_ID:-}" ]] && team=(DEVELOPMENT_TEAM="$LP_TEAM_ID" -allowProvisioningUpdates)
  xcodebuild -project "$src/Local Productivity.xcodeproj" -scheme "Local Productivity" -configuration Release \
    -derivedDataPath "$derived" MARKETING_VERSION="$version" "${team[@]}" build 2>&1 \
    | grep -E "error:|\*\* BUILD (SUCCEEDED|FAILED)" | tail -3
  local app
  app=$(find "$derived/Build/Products/Release" -maxdepth 1 -name "*.app" | head -1)
  [[ -n "$app" ]] || fail "No app was built for $version."
  mkdir -p "${zip:h}"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
}

step "3. Back up the release being replaced"
PREVIOUS=$(git tag --list 'v*' --sort=-v:refname | head -1)
if [[ -z "$PREVIOUS" ]]; then
  echo "There is no earlier release to back up."
elif gh release view "$PREVIOUS" --json assets --jq '.assets[].name' 2>/dev/null | grep -q '\.zip$'; then
  echo "$PREVIOUS is backed up: $(gh release view "$PREVIOUS" --json url --jq .url)"
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

step "4. Release build of $TAG"
ZIP="$ROOT/.build/releases/LP-$VERSION.zip"
build_release "$ROOT" "$VERSION" "$ZIP"
echo "Built ${ZIP#$ROOT/} ($(du -h "$ZIP" | cut -f1 | tr -d ' '))."

step "5. Publish"
# The notes are the version's "## <version>" entry in CHANGELOG.md, or else the commit list.
NOTES=$(awk -v version="$VERSION" '/^## / { if (found) exit; found = ($2 == version); next } found' CHANGELOG.md 2>/dev/null || true)
if [[ -z "${NOTES//[[:space:]]/}" ]]; then
  NOTES=$(git log --no-merges --pretty='- %s' "${PREVIOUS:+$PREVIOUS..}HEAD")
fi
if [[ -n "$PREVIOUS" ]]; then
  NOTES+=$'\n\n'"If this release has a problem: Scripts/rollback.sh ${PREVIOUS#v}"
fi
ASSETS=("$ZIP")
GUIDE="docs/LP User Guide.pdf"
if [[ -f "$GUIDE" ]]; then
  ASSETS+=("$GUIDE#LP User Guide (PDF)")
fi
if (( DRY_RUN )); then
  echo "(dry run) Would tag $TAG, push main and $TAG, and publish ${ZIP:t}${GUIDE:+ and the user guide} with these notes:"
  echo "$NOTES"
  exit 0
fi
git tag -a "$TAG" -m "LP $VERSION"
git push -q origin main "$TAG"
gh release create "$TAG" "${ASSETS[@]}" --title "LP $VERSION" --notes "$NOTES"
print -P "%F{green}✓ Released $TAG%f: $(gh release view "$TAG" --json url --jq .url)"
