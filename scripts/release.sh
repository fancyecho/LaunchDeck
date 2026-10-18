#!/usr/bin/env bash
# Builds a release, zips it and publishes it as a GitHub release, which the
# in-app updater picks up.
#
# 1. Bump CFBundleShortVersionString (and CFBundleVersion) in Resources/Info.plist
# 2. Commit and push
# 3. scripts/release.sh ["release notes"]
#
# Needs the GitHub CLI (`gh auth login`).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
NOTES="${1:-}"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists; bump the version in Resources/Info.plist first." >&2
  exit 1
fi

scripts/build-app.sh release
ZIP="build/LaunchDeck-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/LaunchDeck.app "$ZIP"

if [[ -n "$NOTES" ]]; then
  gh release create "$TAG" "$ZIP" --title "LaunchDeck $VERSION" --notes "$NOTES"
else
  gh release create "$TAG" "$ZIP" --title "LaunchDeck $VERSION" --generate-notes
fi
echo "Published $TAG"
