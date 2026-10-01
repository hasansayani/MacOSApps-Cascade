#!/bin/bash
# Usage: ./release.sh <version> [notes-file]
# Bumps the version, builds, commits, tags, pushes, and publishes a GitHub Release with the zip.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version> [notes-file]}
NOTES=${2:-}
TAG="v$VERSION"

command -v gh >/dev/null || { echo "GitHub CLI not found: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not signed in: gh auth login"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree is not clean; commit or stash first."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Tag $TAG already exists."; exit 1; }

PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" "$PLIST"

./build.sh
ZIP="build/Cascade-$VERSION.zip"
(cd build && shasum -a 256 "Cascade-$VERSION.zip" > "Cascade-$VERSION.zip.sha256")

git add "$PLIST"
git commit -m "Release $VERSION"
git tag -a "$TAG" -m "Cascade $VERSION"
git push origin HEAD --follow-tags

if [ -n "$NOTES" ]; then
  gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "Cascade $VERSION" --notes-file "$NOTES" --latest
else
  gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "Cascade $VERSION" --generate-notes --latest
fi
