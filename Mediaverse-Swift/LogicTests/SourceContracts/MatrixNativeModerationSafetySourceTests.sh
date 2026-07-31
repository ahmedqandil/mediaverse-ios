#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
views="$root/Social/Vibes/MatrixNativeVibesViews.swift"

require() {
  local needle="$1"
  local file="$2"
  local message="$3"
  if ! grep -Fq "$needle" "$file"; then
    printf 'FAIL: %s\n' "$message" >&2
    exit 1
  fi
}

require 'timeline.fetchDetailsForEvent(eventId: eventID)' "$repository" \
  'reports must hydrate the authoritative live Matrix event'
require 'liveEvent.sender == senderID' "$repository" \
  'reports must reject a stale or substituted sender'
require 'liveItem?.kind != .redacted' "$repository" \
  'reports must reject events redacted after presentation'
require 'liveItem?.kind != .unableToDecrypt' "$repository" \
  'reports must not submit undecryptable evidence'
require 'submittedReportFingerprints.insert(fingerprint).inserted' "$repository" \
  'exact report retries must converge without duplicate Synapse reports'
require 'submittedReportOrder.count > 512' "$repository" \
  'report deduplication state must remain bounded'
require 'powerLevels.canOwnUserKick()' "$repository" \
  'member removal must recheck current Matrix power'
require 'powerLevels.canOwnUserBan()' "$repository" \
  'ban and unban must recheck current Matrix power'
require 'MatrixNativeMemberModerationSheet' "$views" \
  'destructive member moderation must use a confirmation sheet'
require 'Reason (optional)' "$views" \
  'member moderation must offer bounded audit reason capture'
require 'Matrix will recheck your current power level' "$views" \
  'role-change confirmation must disclose authoritative revalidation'

printf 'Matrix native moderation safety source checks passed.\n'
