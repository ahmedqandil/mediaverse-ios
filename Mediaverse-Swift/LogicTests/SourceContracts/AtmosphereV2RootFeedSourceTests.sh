#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
contracts="$root/Social/Contracts/AtmoV2Contracts.swift"
client="$root/Services/APIClient.swift"
view_model="$root/Social/Atmosphere/AtmosphereViewModel.swift"
view="$root/Social/Atmosphere/AtmosphereView.swift"

grep -Fq 'public static let feedPath = "/api/v2/atmosphere/feed"' "$contracts"
grep -Fq 'public actor WestreemAtmosphereV2Repository' "$contracts"
grep -Fq 'video.type.lowercased() == "video"' "$contracts"
grep -Fq 'post.status == "PUBLISHED"' "$contracts"
grep -Fq 'reason == "FOLLOWED_CHANNEL" && video.channel != nil' "$contracts"
grep -Fq 'reason == "FOLLOWED_SHOW" && video.show != nil' "$contracts"
grep -Fq 'reason == "EXPLICIT_VIBE_HIGHLIGHT"' "$contracts"
grep -Fq 'highlight.visibility == "PUBLIC"' "$contracts"
grep -Fq '!highlight.encrypted' "$contracts"
grep -Fq 'highlight.shareAllowed' "$contracts"
grep -Fq 'throw AtmoV2RepositoryError.invalidPayload' "$contracts"

grep -Fq 'private let atmosphereRepository: WestreemAtmosphereV2Repository' "$view_model"
grep -Fq 'let page = try await atmosphereRepository.page()' "$view_model"
grep -Fq 'let page = try await atmosphereRepository.page(cursor: cursor)' "$view_model"
grep -Fq 'func loadMoreAtmosphere() async' "$view_model"
grep -Fq 'atmosphereItems = []' "$view_model"
grep -Fq 'atmosphereGeneration' "$view_model"
grep -Fq 'NotificationCenter.default.publisher(for: .userFollowChanged)' "$view"
grep -Fq '.refreshable { await model.reload(.atmosphere) }' "$view"
grep -Fq '.task { await model.loadMoreAtmosphere() }' "$view"
grep -Fq 'AtmosphereAtmoPostCard(post: post)' "$view"
grep -Fq 'AtmospherePublicVibeHighlightCard(highlight: highlight)' "$view"

grep -Fq '"X-Westreem-Platform"' "$client"
grep -Fq 'req.setValue("ios"' "$client"
grep -Fq 'path == AtmosphereV2Authority.feedPath' "$client"

if grep -Fq 'api.atmosphere()' "$view_model"; then
  echo "Root Atmosphere can still read the retired subscriptions feed" >&2
  exit 1
fi

if grep -Fq 'AtmosphereFeedItem' "$view_model"; then
  echo "Root Atmosphere still stores the legacy Fan Club feed union" >&2
  exit 1
fi

if grep -Fq '.rippleCreated' "$view"; then
  echo "Legacy Vibe Ripples can still be injected into root Atmosphere" >&2
  exit 1
fi

echo "Atmosphere v2 root feed source contract passed"
