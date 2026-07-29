#!/bin/bash
set -euo pipefail

composer="Social/Ripples/RippleComposer.swift"
upload="Social/Ripples/RippleMediaUploadCoordinator.swift"
playback="Social/Ripples/RippleCard.swift"

grep -q "SocialRealtimeRollout.voiceRipplesEnabled" "$composer" \
  || { echo "FAIL: Voice Ripple composer must require the shared rollout gate."; exit 1; }
grep -q "SocialRealtimeRollout.videoRipplesEnabled" "$composer" \
  || { echo "FAIL: Video Ripple composer must require the shared rollout gate."; exit 1; }
grep -q "matching: .videos" "$composer" \
  || { echo "FAIL: Video Ripple selection must use the native video picker."; exit 1; }
grep -q "RippleVoiceRecorder" "$composer" \
  || { echo "FAIL: Voice recording must use the isolated native recorder."; exit 1; }
grep -q "URLSessionConfiguration.background" "$upload" \
  || { echo "FAIL: Conversational media must use a background upload session."; exit 1; }
grep -q "social.ripple-media.upload-jobs.v1" "$upload" \
  || { echo "FAIL: Upload jobs must survive process interruption."; exit 1; }
grep -q "mediaJob?.createAttachment" "$composer" \
  || { echo "FAIL: Publishing must use the server-issued stable media ID."; exit 1; }
grep -q "VideoPlayer(player: player)" "$playback" \
  || { echo "FAIL: READY Video Ripples need native playback."; exit 1; }
grep -q "case .voice, .videoMessage" "$playback" \
  || { echo "FAIL: Ripple rendering must exhaustively support both media types."; exit 1; }

echo "Swift Wave conversational-media source contracts passed."
