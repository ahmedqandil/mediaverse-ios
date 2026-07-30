#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
stories_client="$root/Services/StoriesAPIClient.swift"
stories_repository="$root/Services/StoriesRepository.swift"
home="$root/Views/Home/HomeView.swift"
atmosphere_contract="$root/Social/Contracts/AtmoV2Contracts.swift"
atmosphere_view="$root/Social/Atmosphere/AtmosphereView.swift"

grep -Fq 'var path = "/api/stories"' "$stories_client"
grep -Fq 'myPublisherType: publisher?.type' "$stories_repository"
grep -Fq 'myPublisherId: publisher?.id' "$stories_repository"
grep -Fq 'case "channel":' "$stories_repository"
grep -Fq 'case "show":' "$stories_repository"
grep -Fq 'case "user":' "$stories_repository"
grep -Fq 'NotificationCenter.default.notifications(named: .userFollowChanged)' "$stories_repository"
grep -Fq 'StoryTrayView(' "$home"

grep -Fq 'case "ATMO_POST":' "$atmosphere_contract"
grep -Fq 'case "VIDEO":' "$atmosphere_contract"
grep -Fq 'case "MATRIX_HIGHLIGHT":' "$atmosphere_contract"
grep -Fq 'guard listing.normalizedTemplateType != "stories" else { return nil }' "$atmosphere_view"

if grep -Fq 'allowsFlashes: true' "$atmosphere_view"; then
  echo "The Atmosphere still renders curated Flash/story listings" >&2
  exit 1
fi

echo "Flash tray and Atmosphere separation source contract passed"
