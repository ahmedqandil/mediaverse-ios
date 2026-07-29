#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
card="$repo_dir/Social/Ripples/RippleCard.swift"
destination="$repo_dir/Social/Vibes/SocialDestinationViews.swift"
models="$repo_dir/Social/Contracts/SocialModels.swift"

assert_contains() {
  needle=$1
  file=$2
  message=$3
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $message"
    return 1
  fi
}

assert_not_contains() {
  needle=$1
  file=$2
  message=$3
  if grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $message"
    return 1
  fi
}

failures=0

assert_contains 'presentation: RippleCardPresentation = .social' "$card" \
  "RippleCard must remain social by default." || failures=$((failures + 1))
assert_contains 'presentation: detail.club.isPersonal ? .social : .waveConversation' "$destination" \
  "Only community Vibes may opt into the Wave conversation treatment." || failures=$((failures + 1))
assert_contains 'ForEach(conversationReplies.prefix(2))' "$card" \
  "Swift must preview up to two replies before opening the full discussion." || failures=$((failures + 1))
assert_contains 'private var conversationParticipants: [SocialIdentity]' "$card" \
  "Participant avatars must be deduplicated by canonical user id." || failures=$((failures + 1))
assert_not_contains 'guard !(editedCommentsDisabled ?? ripple.commentsDisabled) else { return }' "$card" \
  "Closed comments must disable replying, not access to historical discussion." || failures=$((failures + 1))
assert_not_contains '.disabled(editedCommentsDisabled ?? ripple.commentsDisabled)' "$card" \
  "Closed comments must not disable the historical-discussion entry point." || failures=$((failures + 1))
assert_contains 'guard presentation == .waveConversation else { return "Comment" }' "$card" \
  "Social cards must retain the Comment label." || failures=$((failures + 1))
assert_contains 'return ripple.wave?.type == .questions ? "Answer" : "Reply"' "$card" \
  "Wave cards must label the shared mutation Reply or Answer without changing its contract." || failures=$((failures + 1))
assert_contains 'conversationSummary' "$models" \
  "Swift must decode the additive server-owned conversation summary with a legacy fallback." || failures=$((failures + 1))
assert_contains 'ripple.conversationSummary' "$card" \
  "Swift Wave cards must prefer server-owned participants, activity, unread state, and capabilities." || failures=$((failures + 1))

if [ "$failures" -ne 0 ]; then
  echo "$failures Swift Wave Ripple source contract(s) failed."
  exit 1
fi

echo "Swift Wave Ripple source contracts passed."
