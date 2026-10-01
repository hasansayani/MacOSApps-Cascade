#!/bin/bash
# Builds Cascade and installs it into /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

DEST=/Applications/Cascade.app
pkill -x Cascade 2>/dev/null || true
rm -rf "$DEST"
cp -R build/Cascade.app "$DEST"
# A rebuilt ad-hoc binary has a new signature, so any old Accessibility grant no longer matches.
tccutil reset Accessibility local.cascade.Cascade >/dev/null 2>&1 || true
open "$DEST"
echo "✓ Installed to $DEST — look for the cascade icon in the menu bar."
