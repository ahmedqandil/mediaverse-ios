#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
models="$root/Social/Events/VibeEventModels.swift"
views="$root/Social/Events/VibeEventsViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
session="$root/Services/MatrixSessionCoordinator.swift"
api="$root/Services/APIClient.swift"
stage_view="$root/Social/Vibes/MatrixNativeLiveStageView.swift"
rtc_view="$root/Social/Vibes/MatrixNativeRtcRoomView.swift"

grep -q 'com.westreem.live.speaker.v1' "$models"
grep -q 'com.westreem.live.stage.v1' "$models"
grep -q 'matrixRequestEventId' "$models"
grep -q 'stageAuthority == "MATRIX"' "$views"
grep -q 'sendEventLiveStageAction' "$views"
grep -q 'matrixEventID: matrixEventID' "$views"
grep -q 'func sendLiveStageAction' "$repository"
grep -q 'remoteEventID' "$repository"
grep -q 'client_request_id' "$repository"
grep -q 'func sendEventLiveStageAction' "$session"
grep -q 'matrixEventID: String?' "$api"
grep -q 'context: "stage"' "$api"
grep -q 'expectsPublish: isSpeakerOrHost' "$stage_view"
grep -q 'transportCanPublish != isSpeakerOrHost' "$stage_view"
grep -q 'updateLiveStageCohost' "$stage_view"
grep -q 'observedLiveStages' "$repository"
grep -q 'eligibleSpeakers.sorted().first' "$repository"
grep -q 'requestedAt: isCancelling ? 0' "$repository"
grep -q 'let context: String?' "$rtc_view"

# Native cutover must not acknowledge the Westreem projection before the
# signed-in SDK has produced an immutable remote event ID.
send_line="$(grep -n 'matrixSession.sendEventLiveStageAction' "$views" | head -1 | cut -d: -f1)"
ack_line="$(grep -n 'APIClient.shared.updateVibeEventStage' "$views" | tail -1 | cut -d: -f1)"
test "$send_line" -lt "$ack_line"

echo "Matrix-native Event live-stage source contract passed"
