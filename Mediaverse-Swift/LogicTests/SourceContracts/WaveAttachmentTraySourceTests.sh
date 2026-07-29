#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
view="$repo_dir/Social/Vibes/SocialDestinationViews.swift"

for capability in allowPhotos allowPolls allowVoiceMessages allowVideoMessages allowLinks; do
  grep -Fq -- "wave?.$capability" "$view" || {
    echo "FAIL: attachment tray must explicitly gate $capability."
    exit 1
  }
done
if grep -Fq 'SocialRealtimeRollout.voiceRipplesEnabled' "$view" || grep -Fq 'SocialRealtimeRollout.videoRipplesEnabled' "$view"; then
  echo "FAIL: Westreem-owned media creation must not be blocked by Matrix projection rollout."
  exit 1
fi
grep -Fq 'selectedComposerTool = tool' "$view" || { echo "FAIL: focused tool is not retained."; exit 1; }
grep -Fq 'openFocusedComposer(tool)' "$view" || { echo "FAIL: focused composer transition missing."; exit 1; }
grep -Fq 'guard selectedComposerTool == tool, selectedWave != nil else { return }' "$view" || {
  echo "FAIL: delayed composer transition must preserve its Wave and selected tool."
  exit 1
}
for tool in photo camera poll voice video link sticker event; do
  grep -Fq -- ".$tool" "$view" || {
    echo "FAIL: complete Wave creation tray is missing $tool."
    exit 1
  }
done

echo "Swift Wave attachment tray source contracts passed."
