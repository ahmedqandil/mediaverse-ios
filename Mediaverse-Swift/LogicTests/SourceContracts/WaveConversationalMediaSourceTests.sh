#!/bin/bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
composer="$root/Social/Ripples/RippleComposer.swift"
upload="$root/Social/Ripples/RippleMediaUploadCoordinator.swift"
playback="$root/Social/Ripples/RippleCard.swift"

grep -q "wave.allowVoiceMessages" "$composer" \
  || { echo "FAIL: Voice Ripple composer must honor the Wave setting."; exit 1; }
grep -q "wave.allowVideoMessages" "$composer" \
  || { echo "FAIL: Video Ripple composer must honor the Wave setting."; exit 1; }
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
