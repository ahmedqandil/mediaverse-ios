#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
tokens="$root/Social/Vibes/DesignTokens.swift"
constants="$root/Constants.swift"

require() {
  grep -Fq -- "$1" "$2" || {
    echo "FAIL: $3" >&2
    exit 1
  }
}

# Exact Design System palette values must live in the shared iOS token layer.
for token in \
  'ink950 = Color(hex: "#070A09")' \
  'ink900 = Color(hex: "#0B0F0E")' \
  'ink800 = Color(hex: "#0E1211")' \
  'ink700 = Color(hex: "#151A18")' \
  'lineSoft = Color(hex: "#1B2320")' \
  'lineHard = Color(hex: "#2A332F")' \
  'green = Color(hex: "#00E676")' \
  'pink = Color(hex: "#FF3D8A")' \
  'lavender = Color(hex: "#B388FF")' \
  'text = Color(hex: "#E7EFEB")' \
  'muted = Color(hex: "#7E8F89")'; do
  require "$token" "$tokens" "missing Design System palette token: $token"
done

for token in \
  'static let xs: CGFloat = 4' \
  'static let s: CGFloat = 8' \
  'static let m: CGFloat = 12' \
  'static let l: CGFloat = 16' \
  'static let xl: CGFloat = 24' \
  'static let xxl: CGFloat = 32' \
  'static let small: CGFloat = 8' \
  'static let control: CGFloat = 10' \
  'static let large: CGFloat = 14' \
  'static let card: CGFloat = large' \
  'static let full: CGFloat = 999'; do
  require "$token" "$tokens" "missing Design System geometry token: $token"
done

require 'static let body = "Manrope"' "$tokens" "body font token must name Manrope"
require 'static let mono = "JetBrains Mono"' "$tokens" "mono font token must name JetBrains Mono"

# Existing semantic consumers must resolve through the token layer, not repeat
# platform-specific hex values in Constants.swift.
for mapping in \
  'static let bg          = WestreemTokens.Palette.ink950' \
  'static let surface     = WestreemTokens.Palette.ink900' \
  'static let elevated    = WestreemTokens.Palette.ink800' \
  'static let overlay     = WestreemTokens.Palette.ink700' \
  'static let text         = WestreemTokens.Palette.text' \
  'static let textMuted    = WestreemTokens.Palette.muted' \
  'static let borderSubtle  = WestreemTokens.Palette.lineSoft' \
  'static let border        = WestreemTokens.Palette.lineHard' \
  'static let watch     = WestreemTokens.Palette.green' \
  'static let accent = WestreemTokens.Palette.green' \
  'static let danger = WestreemTokens.Palette.pink' \
  'static let cardRadius: CGFloat  = WestreemTokens.Radius.card'; do
  require "$mapping" "$constants" "missing Constants token mapping: $mapping"
done

echo "WeStreem Design System iOS token source contract passed."
