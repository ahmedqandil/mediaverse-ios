#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SOURCE="$ROOT/Views/Auth/WestreemEntryAuthSurface.swift"
PROJECT="$ROOT/Mediaverse.xcodeproj/project.pbxproj"

grep -Fq 'westreem-entry-auth-24-b-24-c-24-d' "$SOURCE"
grep -Fq 'Continue with Apple' "$SOURCE"
grep -Fq 'Continue with Google' "$SOURCE"
grep -Fq 'Send me a code' "$SOURCE"
grep -Fq 'Enter the code' "$SOURCE"
grep -Fq 'It expires in 10 minutes.' "$SOURCE"
grep -Fq 'RESEND IN 0:' "$SOURCE"
grep -Fq 'USE A DIFFERENT EMAIL' "$SOURCE"
grep -Fq 'WestreemTokens.Palette.surfaceSunken' "$SOURCE"
grep -Fq 'WestreemTokens.Palette.lineHard' "$SOURCE"
grep -Fq 'WestreemTokens.Palette.green' "$SOURCE"
grep -Fq 'WestreemTokens.Palette.pink' "$SOURCE"
grep -Fq 'WestreemEntryAuthSurface.swift in Sources' "$PROJECT"

if grep -Fq 'requestMagicLink' "$SOURCE"; then
  echo 'Keyed email-code surface must not invoke legacy magic links' >&2
  exit 1
fi

echo 'Westreem entry auth Design System source contract passed'
