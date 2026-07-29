#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
card="$repo_dir/Social/Ripples/RippleCard.swift"
controller="$repo_dir/Social/Ripples/RippleEngagementController.swift"

energy=$(grep -n 'title: "Add Energy"' "$card" | head -1 | cut -d: -f1)
reply=$(grep -n 'title: waveReplyActionTitle' "$card" | head -1 | cut -d: -f1)
echo_action=$(grep -n 'title: "Echo"' "$card" | head -1 | cut -d: -f1)
share=$(grep -n 'title: "Share"' "$card" | head -1 | cut -d: -f1)
test "$energy" -lt "$reply" && test "$reply" -lt "$echo_action" && test "$echo_action" -lt "$share" || {
  echo "FAIL: actions must remain Add Energy, Reply, Echo, Share."
  exit 1
}

for action in 'Button("Edit"' 'Button("Delete"' 'Button("Report"'; do
  grep -Fq -- "$action" "$card" || { echo "FAIL: Wave overflow is missing $action."; exit 1; }
done
grep -Fq 'Text(count > 0 ? "\(title) · \(count)" : title)' "$card" || {
  echo "FAIL: zero action counts must remain hidden."
  exit 1
}
grep -Fq 'apply(try await api.rippleEnergy' "$controller" || {
  echo "FAIL: energy must refresh from authoritative persistence."
  exit 1
}
grep -Fq 'shareCount = try await api.recordShare' "$controller" || {
  echo "FAIL: share count must use the authoritative response."
  exit 1
}
grep -Fq 'completionWithItemsHandler' "$card" || {
  echo "FAIL: native Share accounting must wait for activity completion."
  exit 1
}
if grep -Fq 'Task { await engagement.recordNativeShare() }' "$card"; then
  echo "FAIL: opening the Share sheet must not record a completed share."
  exit 1
fi
grep -Fq 'guard completed else { return }' "$card" || {
  echo "FAIL: cancelled Share activities must not mutate counts."
  exit 1
}
grep -Fq 'Button("Retry Share")' "$card" || {
  echo "FAIL: failed Share accounting must preserve a retry action."
  exit 1
}
grep -Fq '"Retry Energy"' "$card" || {
  echo "FAIL: failed Energy submission must expose retry intent."
  exit 1
}
if grep -Fq 'if !isCompactWaveMessage || isLastInMessageGroup || showsComments' "$card"; then
  echo "FAIL: every grouped Ripple must retain its action bar."
  exit 1
fi
grep -Fq 'echoCount += max(0, count)' "$controller" || {
  echo "FAIL: Echo success must update the visible count."
  exit 1
}

echo "Swift Wave Ripple action source contracts passed."
