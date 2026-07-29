#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
card="$root/Social/Ripples/RippleCard.swift"
destination="$root/Social/Vibes/SocialDestinationViews.swift"

assert_contains() {
  local needle="$1"
  local file="$2"
  local message="$3"
  if ! grep -Fq "$needle" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

assert_contains 'case waveConversation' "$card" \
  "Wave message styling must remain an explicit presentation, isolated from social/Atmosphere cards."
assert_contains 'presentation: detail.club.isPersonal ? .social : .waveConversation' "$destination" \
  "Community Waves must opt into message presentation without changing personal Atmospheres."
assert_contains 'isWaveMessageGrouped(' "$destination" \
  "Wave feeds must calculate adjacent message groups."
assert_contains 'ripple.author.id == previous.author.id' "$destination" \
  "Only consecutive Ripples from the same author may group."
assert_contains 'interval <= 10 * 60' "$destination" \
  "Grouping must enforce the approved ten-minute identity/time boundary."
assert_contains 'ripple.pinnedAt == nil' "$destination" \
  "Pinned Ripples must always establish their own identity."
assert_contains '.general' "$destination" \
  "Grouping must be limited to General or Custom Waves."
assert_contains '.custom' "$destination" \
  "Grouping must be limited to General or Custom Waves."
assert_contains 'isGroupedWithPrevious' "$card" \
  "Grouped rows must suppress repeated identity chrome."
assert_contains 'isLastInMessageGroup' "$card" \
  "The last item in a group must retain labeled contextual actions."
assert_contains 'title: "Add Energy"' "$card" \
  "Add Energy must lead the canonical Wave action order."
assert_contains 'title: waveReplyActionTitle' "$card" \
  "Reply/Answer must follow Add Energy."
assert_contains 'title: "Echo"' "$card" \
  "Echo must follow Reply/Answer."
assert_contains 'title: "Share"' "$card" \
  "Share must follow Echo."
assert_contains 'waveMoreAction' "$card" \
  "More must remain the trailing ownership/moderation/report action."
assert_contains 'return ripple.wave?.type == .questions ? "Answer" : "Reply"' "$card" \
  "Question Waves must call the reply action Answer."
assert_contains 'if count > 0' "$card" \
  "Zero engagement counts must be omitted."
assert_contains 'Button("Edit"' "$card" \
  "Owners/moderators must retain Edit in More."
assert_contains 'Button("Delete"' "$card" \
  "Owners/moderators must retain Delete in More."
assert_contains 'Button("Report"' "$card" \
  "Non-owners must retain Report in More."
assert_contains '.frame(minHeight: 44)' "$card" \
  "Every message action must meet the 44-point touch-target minimum."
assert_contains 'canReplyToConversation' "$card" \
  "Message styling must preserve capability and comments policy."
assert_contains 'LegacySocialAPIAdapter' "$card" \
  "Message styling must reuse existing mutations rather than add presentation-specific APIs."

echo "Wave message-style Ripple source contracts passed."
