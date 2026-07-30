#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
models="$root/Social/Events/VibeEventModels.swift"
views="$root/Social/Events/VibeEventsViews.swift"
session="$root/Services/MatrixSessionCoordinator.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"

for required in \
  'let watchPartyAuthority: String?' \
  'struct EventMatrixWatchPartyContent' \
  'let matrixEventId: String?'; do
  grep -Fq "$required" "$models" || {
    echo "Watch-party client authority contract is missing: $required" >&2
    exit 1
  }
done

for required in \
  'matrixSession.sendEventWatchPartyAction' \
  'request: .init(matrixEventId: matrixEventID)' \
  'Task { await watchCommand(.newEpoch, state: nil) }'; do
  grep -Fq "$required" "$views" || {
    echo "Swift Event UI is not sending the hosting Wave event first: $required" >&2
    exit 1
  }
done

grep -Fq 'eventType: "com.westreem.watch_party.v1"' "$session"
grep -Fq '"com.westreem.watch_party.v1"' "$repository"

send_line="$(grep -n 'matrixSession.sendEventWatchPartyAction' "$views" | head -1 | cut -d: -f1)"
ack_line="$(grep -n 'request: .init(matrixEventId: matrixEventID)' "$views" | head -1 | cut -d: -f1)"
test "$send_line" -lt "$ack_line" || {
  echo "Swift must send the Wave event before acknowledging it to Westreem." >&2
  exit 1
}

echo "Event watch-party WeStreem authority source contract passed"
