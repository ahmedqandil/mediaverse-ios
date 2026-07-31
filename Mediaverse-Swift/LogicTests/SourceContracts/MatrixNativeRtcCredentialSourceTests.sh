#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
api="$root/Services/APIClient.swift"
view="$root/Social/Vibes/MatrixNativeRtcRoomView.swift"

require() {
  grep -Fq "$2" "$1" || { echo "FAIL: $3" >&2; exit 1; }
}

require "$api" 'response.connection.token.utf8.count <= 8_192' 'RTC token must be bounded'
require "$api" '(1...600).contains(response.connection.expiresInSeconds)' 'RTC credentials must be short-lived'
require "$api" 'response.connection.videoEnabled == (intent == .video)' 'RTC publication must remain intent scoped'
require "$view" 'await matrixSession.endMatrixRtcMembership(roomID: room.id)' 'terminal UI lifecycle must clear MatrixRTC membership'
require "$view" 'try await liveKitRoom.localParticipant.setMicrophone' 'microphone permission errors must remain explicit'
require "$view" 'try await liveKitRoom.localParticipant.setCamera' 'camera permission errors must remain explicit'

echo "PASS: native MatrixRTC credential and device lifecycle contracts"
