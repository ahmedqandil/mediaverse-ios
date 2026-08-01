#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
api="$root/Services/APIClient.swift"
view="$root/Social/Vibes/MatrixNativeRtcRoomView.swift"
contract="$root/Social/Contracts/MatrixNativeRtcContract.swift"
cloudflare_contract="$root/Social/Contracts/MatrixNativeCloudflareRtcV1Contract.swift"

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
require "$contract" 'public let providerSessionID: String' 'network recovery must bind the exact provider session'
require "$contract" 'expiresAtMilliseconds <= binding.authorityExpiresAtMilliseconds' 'network recovery expiry must not outlive provider authority'
require "$cloudflare_contract" 'public static let version = "CLOUDFLARE_RTC_V1"' 'Cloudflare RTC DTOs must be independently versioned'
require "$cloudflare_contract" 'public struct MatrixNativeCloudflareRtcV1AuthorizeRequest' 'Cloudflare authorization must have a dedicated request DTO'
require "$cloudflare_contract" 'public struct MatrixNativeCloudflareRtcV1AuthorityResponse' 'Matrix-issued call authority must have a dedicated response DTO'
require "$cloudflare_contract" 'public struct MatrixNativeCloudflareRtcV1ReceiveOnlySessionRequest' 'receive-only SFU session creation must be explicit'
require "$cloudflare_contract" 'tracks = []' 'receive-only session request must encode an empty track list'
require "$cloudflare_contract" 'case providerSessionID = "sessionId"' 'Cloudflare provider sessions must use the shared sessionId wire key'
require "$cloudflare_contract" 'case issuedAtMilliseconds = "issuedAtMs"' 'Cloudflare authority timestamps must use the shared issuedAtMs wire key'
require "$cloudflare_contract" 'case expiresAtMilliseconds = "expiresAtMs"' 'Cloudflare authority timestamps must use the shared expiresAtMs wire key'
require "$cloudflare_contract" 'case requestedTrackKinds = "trackKinds"' 'Cloudflare authorize requests must use the shared trackKinds wire key'
require "$cloudflare_contract" 'case action = "turnAction"' 'Cloudflare recovery requests must use the shared turnAction wire key'
require "$cloudflare_contract" 'public struct MatrixNativeCloudflareRtcV1EphemeralIceServer' 'TURN responses must decode ephemeral ICE servers for RTCPeerConnection'
require "$cloudflare_contract" 'Decodable, Sendable, Equatable, CustomStringConvertible' 'ephemeral ICE DTOs must remain decode-only and redact descriptions'
require "$cloudflare_contract" 'public func takeTransportMaterial(' 'ephemeral ICE material must be consumed exactly once'
require "$cloudflare_contract" 'expiresAtMilliseconds <= binding.authorityExpiresAtMilliseconds' 'ephemeral ICE material must not outlive Matrix provider authority'
require "$cloudflare_contract" 'public let experience: MatrixNativeCloudflareRtcV1Experience' 'Cloudflare authority must echo the server-derived product experience'
require "$cloudflare_contract" 'public let intent: MatrixNativeRtcIntent' 'Cloudflare authority must echo the exact authorized call intent'
require "$cloudflare_contract" 'public let role: MatrixNativeCloudflareRtcV1Role' 'Cloudflare authority must include the Matrix-derived participant role'
require "$cloudflare_contract" 'public let mediaPath: MatrixNativeCloudflareRtcV1MediaPath' 'Cloudflare authority must include the server-selected media path'
require "$cloudflare_contract" 'experience == request.experience' 'iOS must reject product-experience authority substitution'
require "$cloudflare_contract" 'publishAllowed == authority.publishAllowed' 'receive-only creation must preserve Matrix publish authority'
require "$cloudflare_contract" 'public let requiresImmediateRenegotiation: Bool' 'subscription responses must declare renegotiation requirements'
require "$cloudflare_contract" 'public let offer: MatrixNativeCloudflareRtcV1EphemeralSessionDescription?' 'subscription renegotiation offers must be transport-only DTOs'
require "$cloudflare_contract" 'requiresImmediateRenegotiation == (offer != nil)' 'subscription offers must exist exactly when renegotiation is required'
require "$cloudflare_contract" 'public final class MatrixNativeCloudflareRtcV1NetworkRecoveryResponse' 'decoded TURN response must be the shared one-use owner'
require "$cloudflare_contract" 'private let lock = NSLock()' 'one-use TURN ownership must be synchronized'
require "$cloudflare_contract" 'private var availableIceServers:' 'decoded ICE secrets must remain private until transport consumption'
require "$cloudflare_contract" 'rejectUnknownCloudflareRtcV1Keys' 'V1 response DTOs must reject unknown wire keys'
require "$cloudflare_contract" 'public struct MatrixNativeCloudflareRtcV1SubscribeRequest' 'Cloudflare subscription requests must be separate from authorized results'
require "$cloudflare_contract" 'public let subscriberTrackMID: String' 'authorized subscription responses must include server-derived subscriber MID'
require "$cloudflare_contract" 'public struct MatrixNativeCloudflareRtcV1NetworkRecoveryRequest' 'Cloudflare recovery must use a provider-session-bound request DTO'
require "$cloudflare_contract" 'The client requests an action, never a TURN TTL.' 'the server must select TURN and ICE recovery expiry'

if grep -Eq 'public let (sdp|turnUsername|turnPassword|providerCredential|iceServerURL)' "$contract"; then
  echo 'FAIL: shared RTC state must not expose SDP or provider credentials' >&2
  exit 1
fi

if grep -Eq 'public let (turnUsername|turnPassword|providerCredential|iceServerURL)' "$cloudflare_contract"; then
  echo 'FAIL: Cloudflare DTOs must not expose persistent provider credentials' >&2
  exit 1
fi

if grep -Eq 'UserDefaults|Keychain|FileManager|os_log|Logger|print\(' "$cloudflare_contract"; then
  echo 'FAIL: ephemeral ICE material must never be persisted or logged' >&2
  exit 1
fi

if grep -Fq 'opaqueReference' "$cloudflare_contract"; then
  echo 'FAIL: Cloudflare TURN response must be directly executable, not an incomplete opaque-reference exchange' >&2
  exit 1
fi

echo "PASS: native MatrixRTC credential and device lifecycle contracts"
