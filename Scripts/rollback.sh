#!/bin/zsh
# Restores an earlier release of LP.
#
#   Scripts/rollback.sh                  list the releases that can be restored
#   Scripts/rollback.sh 1.0.0            download that release's app into .build/releases/ and show it
#   Scripts/rollback.sh 1.0.0 --source   put that release's code on a new branch, rollback/to-v1.0.0,
#                                        as one commit on top of main, so history is kept
#
# main is never changed here. A source rollback is a branch to check, merge and release with
# Scripts/deploy.sh like any other change — a beta first, official once the owner confirms it.
# Betas (pre-releases) can be downloaded too: Scripts/rollback.sh 1.0.1-beta.1 It restores the app, not the way it is released: the
# release scripts, the documentation and the agent rules stay as they are now.

set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

VERSION="${1:-}"
MODE="${2:-}"
if [[ -z "$VERSION" ]]; then
  echo "Releases you can restore:"
  gh release list --limit 20
  exit 0
fi
TAG="v${VERSION#v}"
git fetch -q origin --tags
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "There is no release $TAG. Run Scripts/rollback.sh to list them."
  exit 1
fi

if [[ "$MODE" == "--source" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or stash your changes first."
    exit 1
  fi
  BRANCH="rollback/to-$TAG"
  git switch -q -c "$BRANCH" origin/main
  # Makes the files match the release exactly, including removing files added since, except the
  # tools and documents that release and describe the project.
  git restore --source="$TAG" --staged --worktree -- . \
    ':(exclude)Scripts/deploy.sh' ':(exclude)Scripts/rollback.sh' \
    ':(exclude)Scripts/make-user-guide.sh' ':(exclude)Scripts/make-user-guide.swift' \
    ':(exclude)docs' ':(exclude)CLAUDE.md' ':(exclude)AGENTS.md' ':(exclude)CODEX.md' ':(exclude)CHANGELOG.md'
  git commit -q -m "Roll back to $TAG" -m "Restores the code of $TAG on top of main. History is kept; release scripts and docs are unchanged."
  echo "Created $BRANCH with the code of $TAG."
  echo "Next, as with any change (docs/RELEASING.md): set MARKETING_VERSION to a new version (a rollback is"
  echo "released as a new version, e.g. 1.1.1), run Scripts/test.sh && Scripts/build.sh and push $BRANCH."
  echo "Once the owner says yes, publish it as a beta: Scripts/deploy.sh 1.1.1-beta.1 --confirmed"
  echo "Only after the owner confirms that beta: merge into main and Scripts/deploy.sh 1.1.1 --confirmed."
  exit 0
fi

DEST="$ROOT/.build/releases/$TAG"
rm -rf "$DEST"
mkdir -p "$DEST"
gh release download "$TAG" --pattern '*.zip' --dir "$DEST"
ditto -x -k "$DEST"/*.zip "$DEST"
APP=$(find "$DEST" -maxdepth 1 -name "*.app" | head -1)
echo "Restored the app of $TAG: $APP"
echo "Quit LP, then move this app into /Applications in place of the current one."
open -R "$APP"
