#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
api="$root/Services/APIClient.swift"
view="$root/Social/Vibes/MatrixNativeRtcRoomView.swift"
contract="$root/Social/Contracts/MatrixNativeRtcContract.swift"

require() {
  grep -Fq "$2" "$1" || { echo "FAIL: $3" >&2; exit 1; }
}

require "$api" 'response.connection.token.utf8.count <= 8_192' 'RTC token must be bounded'
require "$api" '(1...600).contains(response.connection.expiresInSeconds)' 'RTC credentials must be short-lived'
require "$api" 'response.connection.videoEnabled == (intent == .video)' 'RTC publication must remain intent scoped'
require "$view" 'await matrixSession.endMatrixRtcMembership(roomID: room.id)' 'terminal UI lifecycle must clear MatrixRTC membership'
require "$view" 'private protocol MatrixNativeRtcTransportAdapter' 'RTC transport must have a provider-neutral boundary'
require "$view" 'try await activeTransport?.setTrack(' 'media controls must use the selected transport adapter'
require "$view" 'MatrixNativeCloudflareRealtimeTransportAdapter' 'Cloudflare must have a distinct native adapter seam'
require "$view" 'guard MatrixNativeRtcContract.permitsTrackIntent(.screen)' 'ReplayKit screen publication must remain gated'
require "$view" 'await transport?.disconnect()' 'disconnect must clean up the active provider transport'
require "$view" 'connection.applicationMediaEncryption == false' 'native RTC must reject application media E2EE'
require "$contract" 'public struct MatrixNativeRtcSessionBinding' 'RTC subscription state must bind provider, Wave, call and device immutably'
require "$contract" 'public struct MatrixNativeRtcRemoteTrackSource' 'remote subscriptions must align with the Web remote-track source contract'
require "$contract" 'public let publisherSessionID: String' 'remote track identity must include the publisher session'
require "$contract" 'public let providerTrackName: String' 'remote track identity must include the provider track name'
require "$contract" 'public mutating func unsubscribe(' 'remote subscription lifecycle must support exact unsubscribe cleanup'
require "$contract" 'public mutating func removeParticipant(' 'participant departure must clear all of that participant tracks'
require "$contract" 'public mutating func finish()' 'terminal RTC lifecycle must clear subscription and authorization state'
require "$contract" 'experience == .call || experience == .liveStage' 'only calls and Live Stage interactive roles may subscribe over RTC'
require "$contract" 'maximumNetworkRecoveryAuthorizationLifetimeMilliseconds' 'TURN refresh and ICE restart authorization must be time bounded'
require "$contract" 'public mutating func takeAuthorization(' 'network recovery authorization must be one use'

if grep -Eq 'public let (sdp|turnUsername|turnPassword|providerCredential|iceServerURL)' "$contract"; then
  echo 'FAIL: shared RTC state must not expose SDP or provider credentials' >&2
  exit 1
fi

echo "PASS: native MatrixRTC credential and device lifecycle contracts"
