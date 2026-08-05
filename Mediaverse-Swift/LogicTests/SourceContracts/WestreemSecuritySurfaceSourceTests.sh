#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/Views/Profile/WestreemSecuritySurface.swift"
PROJECT="$ROOT/Mediaverse.xcodeproj/project.pbxproj"

test -f "$SOURCE"
grep -q 'westreem-security-26-d' "$SOURCE"
grep -q 'WHERE YOU ARE SIGNED IN' "$SOURCE"
grep -q 'THIS DEVICE' "$SOURCE"
grep -q 'SIGN IN' "$SOURCE"
grep -q 'Connected accounts' "$SOURCE"
grep -q 'There is no password' "$SOURCE"
grep -q 'You sign in with Apple, Google or a code by email — nothing to reset or leak.' "$SOURCE"
grep -q 'DELETING ASKS TWICE AND NAMES WHAT GOES' "$SOURCE"
grep -q 'RIPPLES, WAVES, COLLECTIONS AND CHANNELS YOU OWN' "$SOURCE"
grep -q 'WestreemTokens.Palette.pink' "$SOURCE"
grep -q 'busySessionID' "$SOURCE"
grep -q 'busyAllOthers' "$SOURCE"
grep -q 'onSignOutSession' "$SOURCE"
grep -q 'onSignOutOthers' "$SOURCE"
grep -q 'onDeleteAccount' "$SOURCE"
! grep -q 'URLSession' "$SOURCE"
! grep -q 'fatalError' "$SOURCE"
grep -q 'WestreemSecuritySurface.swift in Sources' "$PROJECT"

echo "WestreemSecuritySurfaceSourceTests: PASS"
