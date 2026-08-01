#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
views="$root/Social/Vibes/MatrixNativeVibesViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
rtc="$root/Social/Contracts/MatrixNativeRtcContract.swift"
api="$root/Services/APIClient.swift"
constants="$root/Constants.swift"

grep -Fq 'matrixRoom.hasActiveRoomCall()' "$repository"
grep -Fq 'matrixRoom.activeRoomCallParticipants()' "$repository"
grep -Fq 'activeRoomCallConsensusIntent' "$repository"
grep -Fq 'activeCallParticipants: activeParticipants' "$repository"
grep -Fq '"created_ts": createdAt' "$repository"
grep -Fq 'content: membershipJSON()' "$repository"
if grep -Fq 'expiry +=' "$repository"; then
  echo "MatrixRTC membership lifetime must not accumulate across refreshes" >&2
  exit 1
fi
grep -Fq 'title: "Live lounges"' "$views"
grep -Fq 'opensLiveLounge: true' "$views"
grep -Fq '.accessibilityHint("Opens this live lounge")' "$views"
grep -Fq 'case nil: return "Live lounge"' "$views"
if grep -Fq 'Secure calls are preparing' "$views"; then
  echo "Application-level RTC E2EE copy must not remain active" >&2
  exit 1
fi
grep -Fq 'Direct calls are preparing' "$views"
grep -Fq 'applicationMediaEncryptionEnabled = false' "$rtc"
grep -Fq 'swiftBindingsExportMatrixRtcMediaKeys = false' "$rtc"
grep -Fq 'C.isTrustedRtcURL(url)' "$api"
grep -Fq '["https", "wss"].contains(scheme)' "$constants"
grep -Fq 'host.hasSuffix(".fly.dev")' "$constants"

echo "Matrix-native Swift lounge UI source contracts passed"
