#!/bin/sh
set -eu

card="Social/Ripples/RippleCard.swift"
vibe="Social/Vibes/SocialDestinationViews.swift"

require() {
  pattern="$1"
  file="$2"
  message="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require "isGroupedWithPrevious" "$card" "Wave cards must support consecutive-author grouping."
require "isLastInMessageGroup" "$card" "Wave groups must identify their final message."
require "showsMessageActionLabels" "$card" "Only focused/final messages should expand action labels."
require 'return ripple.wave?.type == .questions ? "Answer" : "Reply"' "$card" "Question Waves must say Answer."
require "waveMoreAction" "$card" "Wave message action bar must retain contextual More actions."
require "isWaveMessageGrouped(" "$vibe" "Vibe feed must calculate safe grouping from adjacent Ripples."
require "interval <= 10 * 60" "$vibe" "Grouping must be constrained to a ten-minute author session."
require "ripple.wave?.id == previous.wave?.id" "$vibe" "Messages from different Waves must never group."
require "ripple.pinnedAt == nil" "$vibe" "Pinned Ripples must start their own group."
require "previous.pinnedAt == nil" "$vibe" "Ripples must not group after pinned content."
require "waveType == .general || waveType == .custom" "$vibe" "Specialized Wave content must never group."
require ".frame(minHeight: 44)" "$card" "Wave message actions must retain a 44-point touch target."
require "compactWaveAuthorLine" "$card" "Compact Waves must use message identity rather than the legacy card header."
require ".padding(.leading, isCompactWaveMessage ? 50 : 0)" "$card" "Compact Waves must reserve a visible avatar gutter."
require "isCompactWaveMessage, !usesCompactWaveGrouping" "$card" "Only group leaders may repeat the author avatar."
require "? Color.clear" "$card" "Compact Wave messages must remove legacy card fill."
require "waveChatComposerEntry" "$vibe" "Wave conversations must expose a persistent chat-style composer entry."
require ".safeAreaInset(edge: .bottom" "$vibe" "The Wave composer must remain visible while reading."

energy_line=$(grep -n 'title: "Add Energy"' "$card" | head -1 | cut -d: -f1)
reply_line=$(grep -n 'title: waveReplyActionTitle' "$card" | head -1 | cut -d: -f1)
echo_line=$(grep -n 'title: "Echo"' "$card" | head -1 | cut -d: -f1)
share_line=$(grep -n 'title: "Share"' "$card" | head -1 | cut -d: -f1)
more_line=$(grep -n 'waveMoreAction$' "$card" | head -1 | cut -d: -f1)

if ! [ "$energy_line" -lt "$reply_line" ] \
  || ! [ "$reply_line" -lt "$echo_line" ] \
  || ! [ "$echo_line" -lt "$share_line" ] \
  || ! [ "$share_line" -lt "$more_line" ]; then
  echo "FAIL: Wave actions must remain Add Energy, Reply/Answer, Echo, Share, More." >&2
  exit 1
fi

echo "Wave message Ripple source contracts passed."
