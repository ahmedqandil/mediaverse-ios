#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
view="$repo_dir/Social/Vibes/SocialDestinationViews.swift"

for capability in allowPhotos allowPolls allowVoiceMessages allowVideoMessages allowLinks; do
  grep -Fq -- "wave.$capability" "$view" || {
    echo "FAIL: attachment tray must explicitly gate $capability."
    exit 1
  }
done
grep -Fq 'guard let wave else { return [] }' "$view" || { echo "FAIL: tray must fail closed without a Wave."; exit 1; }
grep -Fq 'SocialRealtimeRollout.voiceRipplesEnabled' "$view" || { echo "FAIL: Voice rollout gate missing."; exit 1; }
grep -Fq 'SocialRealtimeRollout.videoRipplesEnabled' "$view" || { echo "FAIL: Video rollout gate missing."; exit 1; }
grep -Fq 'selectedComposerTool = tool' "$view" || { echo "FAIL: focused tool is not retained."; exit 1; }
grep -Fq 'openFocusedComposer(tool)' "$view" || { echo "FAIL: focused composer transition missing."; exit 1; }
grep -Fq 'guard selectedComposerTool == tool, selectedWave != nil else { return }' "$view" || {
  echo "FAIL: delayed composer transition must preserve its Wave and selected tool."
  exit 1
}
grep -Fq '"Attachments unavailable"' "$view" || {
  echo "FAIL: a text-only Wave must explain why its attachment tray is empty."
  exit 1
}
grep -Fq '"This Wave currently accepts text messages only."' "$view" || {
  echo "FAIL: text-only attachment state must remain actionable and clear."
  exit 1
}

echo "Swift Wave attachment tray source contracts passed."
