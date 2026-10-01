#!/bin/bash
# Builds Cascade and installs it into /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

DEST=/Applications/Cascade.app
BUNDLE_ID=local.cascade.Cascade

# Builds before 2.0.1 were signed with a per-build hash requirement, so an existing Accessibility
# entry may belong to an older binary and never match this one. Clear it once; current builds use
# a stable requirement, so later reinstalls keep the permission.
STALE=1
if [ -d "$DEST" ] && codesign -d -r- "$DEST" 2>&1 | grep -q "designated => identifier \"$BUNDLE_ID\""; then
  STALE=0
fi

pkill -x Cascade 2>/dev/null || true
rm -rf "$DEST"
ditto build/Cascade.app "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
if [ "$STALE" = 1 ]; then
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "→ Cleared the old Accessibility entry; macOS will ask once more."
fi
open "$DEST"
echo "✓ Installed to $DEST — look for the cascade icon in the menu bar."
