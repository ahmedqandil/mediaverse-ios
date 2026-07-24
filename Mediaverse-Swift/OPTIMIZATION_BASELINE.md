# Mediaverse Optimization Baseline

This document defines the regression boundary for performance work. Optimization must preserve visible UI, interaction behavior, navigation, backend contracts, analytics, access decisions, and media output.

## Verified Starting Point

- One iPhone application target, deployment target iOS 17.
- SwiftUI application with UIKit and AVFoundation bridges.
- MetalPetal 1.25.2 is the only external package.
- A clean unsigned simulator build succeeds on the current working tree.
- The Xcode project currently has no unit-test or UI-test target. A lightweight Swift package now runs routing contract tests independently without changing the application target or scheme.
- Existing uncommitted product work predates this optimization program and must be preserved.

## Critical Business Contracts

The following behavior must be covered before its implementation is refactored:

1. Mobile session restoration, refresh, sign-out, and active context switching.
2. Universal-link, custom-scheme, push-notification, mention, and handoff routing.
3. Signed-out, free, SVOD, PPV, and rental playback decisions.
4. Video and episode progress payloads, restoration, and the 95-percent completion rule.
5. Channel/show subscriptions, likes, comments, replies, flags, posts, and moment likes.
6. Collection and playlist ownership, mutation, ordering, and follow behavior.
7. Shorts paging, playback ownership, contextual routing, social actions, and ads.
8. Story project persistence, editing, export, publishing, expiry, and viewer permissions.
9. Creator destination lookup, resumable upload, record creation, processing, and readiness.
10. Ad eligibility, break scheduling, tracking, fullscreen handoff, and content resumption.

## Performance Metrics

The in-process metrics collector records cache counters and duration samples. Initial timing namespaces are:

- `startup.bootSplash`: process initialization through boot-splash dismissal.
- `startup.warmup.total`: complete deferred main-page warmup.
- `startup.warmup.batch`: each dependency batch within warmup.

Metrics are intentionally passive: they do not emit network traffic, persist user data, or alter release behavior. Additional screen-specific measurements should use the same collector so before/after samples remain comparable.

## Required Validation Per Batch

1. Review the exact diff and confirm no unrelated existing changes were overwritten.
2. Build the application for an iPhone simulator without code signing.
3. Run available contract and regression tests.
4. Exercise affected loading, success, empty, error, signed-out, and restricted states.
5. Compare affected screens and gestures against the pre-change behavior.
6. Record the relevant before/after timing, memory, network, or cache measurement.

## Optimization Order

1. Regression tests and API fixtures.
2. Startup and screen performance measurement.
3. Duplicate-request prevention and cancellation.
4. Image decoding, caching, and prefetch control.
5. Home feed lifecycle and rendering.
6. Player ownership and observer cleanup.
7. Shorts lifecycle and memory.
8. Story preview, composition, and export.
9. Upload memory and background behavior.
10. Domain separation for models and networking.

## Resolved Contract Issue

- Path-form media links now take precedence over generic context query values. A short such as `/watch/{id}?type=short&showId={context}` opens the short and preserves its show context instead of incorrectly opening the show.

## Completed Optimization Batches

### Batch 1: observability and warmup lifecycle

- Added passive launch, total-warmup, and warmup-batch duration metrics.
- Added routing contract tests without changing the application scheme.
- Added generation-aware warmup completion so a cancelled warmup cannot clear or cooldown a newer replacement task.
- Preserved all pre-existing uncommitted startup, media-cache, and screen changes.

### Batch 2: duplicate GET prevention

- Extended in-flight request coalescing to volatile GET endpoints without caching their responses.
- Concurrent identical Profile, notification, progress, history, entitlement, and backstage reads now share only the active network operation.
- Kept authentication token, active context, path, and authenticated/public mode in the coalescing identity.
- Added request generation IDs so an older completion cannot clear a newer in-flight request after cache invalidation.

### Batch 3: screen lifecycle ownership

- Added explicit Home load generations and cancellation on context changes or disappearance.
- Old-context Home responses can no longer overwrite the current feed after a context switch.
- Home cleanup is generation-aware, so an older task cannot clear a newer task's loading state.
- Notification mutations invalidate an older inbox load, preventing stale unread state from replacing optimistic read updates.

### Batch 4: media and image-request ownership

- Added generation ownership to shared remote-image requests, so completion of an older cancelled request cannot remove a newer request for the same image key.
- Preserved image-request coalescing, memory and disk cache limits, downsampling, and visible loading behavior.
- Episode playback now retains the exact `AVPlayer` that owns its periodic moment observer and removes the observer from that player during replacement or teardown.
- Audited periodic player and notification observer paths across video, episode, ad, feed-preview, player-chrome, and story-editor flows; the remaining paths already pair registration with cleanup.
- Verified with 7 routing contract tests, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 5: Shorts lifecycle and stale-response protection

- Consolidated five independent autoplay retry tasks into one cancellable retry sequence owned by the Shorts screen.
- Autoplay retry work is now cancelled when the Shorts tab becomes inactive or the screen disappears, preventing delayed offscreen activation attempts.
- Added feed-generation ownership to initial loads, pagination, refreshes, and feed switches so results from an older feed session cannot overwrite the current selection.
- Preserved the existing bounded resource windows: at most five pager pages are materialized, while players and warmed assets remain limited around the active short and are trimmed further on memory pressure.
- Preserved feed ordering, ad injection and locking, view recording, playback selection, mute state, and pagination behavior.
- Verified with 7 routing contract tests, lifecycle invariant inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 6: Story export resource ownership

- Story exports now delete their temporary source output after the durable bounded export-cache copy succeeds or fails.
- Audio-muxed video exports remove the intermediate rendered video once the muxed output owns the result.
- Cancelled or failed frame-writer exports explicitly stop an active `AVAssetWriter` and remove partial output files.
- Preserved export cache keys, codec and bitrate settings, rendered frames, audio composition, upload inputs, progress phases, and editor UX.
- Audited editor preview rendering and playback lifecycle; preview render tasks, player observers, watchdog work, and compositor caches already cancel or clear on replacement and disappearance.
- Verified with 7 routing contract tests, export-ownership invariant inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 7: upload completion and cancellation safety

- Confirmed large creator uploads are streamed from disk through the resumable TUS path in bounded 8 MB chunks; story media uploads also use file-backed URLSession transfers.
- Added explicit cancellation checks between TUS chunks so cancellation stops before reading or accepting another chunk response.
- Validate that every TUS server offset advances, stays within the selected file size, and reaches the exact final byte count before media metadata is created.
- A selected file that changes or truncates during upload now fails safely instead of being treated as a completed transfer.
- Transcode polling now exits cleanly when cancelled instead of swallowing cancellation and entering a rapid retry loop.
- Preserved upload limits, endpoints, headers, resume offsets, chunk size, thumbnail selection, progress percentages, creation payloads, notification behavior, and visible UX.
- Verified with 7 routing contract tests, upload-protocol invariant inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 8: authentication generation and privacy isolation

- Added authentication generations so a cold-start session check or background profile refresh cannot apply after login, sign-out, biometric restoration, or session expiry changes ownership.
- Automatic 401 expiry now clears user-scoped memory and disk caches after immediately transitioning the UI to signed out, matching manual sign-out privacy behavior.
- Foreground mobile-token refresh is now single-flight, preventing repeated active-scene events from starting duplicate refresh requests.
- Refresh work is cancelled and invalidated during sign-out or expiry, while refresh failures continue to preserve the existing session as before.
- The session-expiry notification observer and refresh task now clean up with the authentication manager lifecycle.
- Preserved Keychain storage, biometric gating, magic-link and Google flows, device activation, active-context cookies, immediate authenticated UI transitions, and sign-out server behavior.
- Verified with 7 routing contract tests, session/cache-isolation invariant inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 9: active-context response isolation

- Context-list reads now persist the server's active context only while the request's starting context cookie still owns the session.
- An older context response can no longer overwrite a newly confirmed user, channel, or show context.
- Upload-options warmups now use request IDs, so cancellation or completion of older work cannot clear or publish over its replacement.
- Upload options automatically refetch under the current context when the context changes during a shared or direct request.
- Preserved server-confirmed context switching, cookie format, navigation resets, screen reload notifications, upload destination selection, and visible UX.
- Verified with 7 routing contract tests, context-ownership invariant inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 10: mutation-to-read consistency

- Added an API response generation boundary so reads started before a successful mutation cannot publish or return pre-mutation data afterward.
- Older cached and uncached GET operations now transparently refetch when a mutation, context switch, or targeted content invalidation changes server state.
- Shared in-flight readers validate ownership after awaiting the shared operation instead of accepting an older generation's response.
- Disk-backed API responses are no longer trusted after an in-session mutation until a fresh response has been written under the current generation.
- Targeted invalidation now includes requests that are still in flight, not only responses already present in memory.
- Preserved endpoint payloads, cache TTLs, request coalescing, stale-on-network-error behavior, mutation UX, and all UI rendering.
- Verified with 7 routing contract tests, memory/disk invalidation invariant inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Corrective QA: stable tab navigation roots

- Removed lazy insertion of tab root views inside their existing `NavigationStack` containers after device QA exposed a UIKit navigation-bar ownership crash.
- Every tab now owns a stable root navigation item for the full lifetime of the page-style tab container, preventing the Profile item from moving between wrapped navigation bars during a transition.
- Preserved tab order, horizontal paging, navigation paths, custom bottom controls, screen UI, and deferred startup/network warmups.
- Verified with 7 routing contract tests, navigation-container inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 11: deep-link destination precedence

- Dedicated query destinations such as `shortId`, `videoId`, `episodeId`, and `microdramaId` retain highest routing priority.
- Concrete URL paths now resolve before generic `showId`, `channelId`, playlist, or collection query-only fallbacks.
- Path-form short links preserve optional show and channel context for the Shorts feed instead of discarding it.
- Prevented video, short, and channel links from being redirected to unrelated contextual query destinations.
- Preserved notification payload precedence, custom-scheme parity, route identities, navigation presentation, and all visible UI.
- Added the previously missing regression contract and verified with 8 routing tests, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Corrective QA: Shorts first-activation loading

- Restored the initial Shorts feed load after stable tab navigation roots made the Shorts view exist before its tab became active.
- Root tab activation now starts the existing guarded load path even while the feed is empty; playback-only observers continue to run after cards exist.
- Preserved stable navigation ownership, request prewarming, restored feed sessions, routed Shorts, pagination, playback, and visible UI.
- Verified with 8 routing contract tests, activation-lifecycle inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 12: stable-root offscreen work control

- Profile keeps its stable navigation root but defers the five-request account refresh until the tab is first selected.
- Returning to an already loaded Profile refreshes time-sensitive billing and notification counts without rebuilding the screen.
- Authentication and context ownership changes invalidate Profile state and trigger a full refresh on the next active presentation.
- Explore defers its curation refresh while inactive while retaining the mounted subsection content, filters, scroll position, and navigation item.
- Preserved page-style tab transitions, navigation-bar ownership, screen state, pull-to-refresh, UI, and all account business logic.
- Verified with 8 routing contract tests, activation-state inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 13: Explore subsection activation gates

- Shows, Videos, Movies, Microdramas, Channels, Following, and Collections now defer their initial data request until Explore is active.
- Subsection views remain mounted, so the selected section, filters, search text, scroll state, and loaded results survive tab switches.
- A section selected while Explore is visible loads through its existing task path; an already loaded section does not refetch merely because the user returns to Explore.
- Offscreen Videos also cancels pending preview selection work and pauses preview playback without discarding its feed.
- Preserved pull-to-refresh, pagination, authentication gates, curation behavior, navigation identity, UI, and stable navigation-bar ownership.
- Verified with 8 routing contract tests, subsection activation inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 14: Explore account-state isolation

- Following and Collections now clear account-owned results, pending mutation state, and modal presentation state immediately on sign-out.
- Both screens use authentication generations so an older account's late response cannot repopulate state after sign-out or account replacement.
- Signing in while a screen is active reloads immediately; signing in while it is offscreen marks it for loading on the next Explore activation.
- Preserved public collection fetching within the authenticated Collections experience, follow/delete/create behavior, pull-to-refresh, tabs, and UI.
- Verified with 8 routing contract tests, auth-transition ownership inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 15: Explore latest-selection ownership

- Shows, Movies, Microdramas, and Channels now assign generations to section and refresh loads so only the latest request may publish screen state.
- Rapid genre or curated-section changes can no longer be overwritten by a slower response for the previous selection.
- Show search uses a separate generation and query check; editing or clearing the query invalidates the pending search and ends its loading state.
- Continue-watching results are committed under the same generation as their paired curation response.
- Preserved cached-first rendering, fallback content, section selection, search UX, pull-to-refresh, and UI.
- Verified with 8 routing contract tests, overlapping-request inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 16: Videos and Profile request ownership

- Videos curation refreshes and cursor pagination now publish only while their request generation still owns the screen.
- Pagination binds to its starting cursor, preventing a late page from appending after a newer refresh or section change.
- Profile account, billing, and notification-count requests use independent generations so faster focused refreshes cannot be overwritten by an older full refresh.
- Authentication and active-context transitions invalidate every Profile request boundary before clearing or reloading account state.
- Preserved video fallbacks, previews, pagination, pull-to-refresh, profile billing/count UI, and all visible behavior.
- Verified with 8 routing contract tests, request-ownership inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 17: Search latest-intent ownership

- Suggestions, trending content, and full results now have independent request generations.
- A slower response for older text or a previous filter can no longer replace results for the user's current query and filter.
- Leaving Search invalidates pending publications while retaining the existing cancellation, history, routing, debounce timing, and offline behavior.
- Preserved search layout, keyboard selection, filters, accessibility announcements, history sync, and navigation.
- Verified with 8 routing contract tests, rapid-query/filter invariant inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 18: Collections mutation account isolation

- Follow and delete mutations capture the authenticated account generation that initiated them.
- A mutation completing after sign-out or account replacement can no longer restore or alter collection state owned by the next session.
- Preserved optimistic follow/delete feedback, rollback-on-failure behavior, creation, tabs, public communities, and UI.
- Verified with 8 routing contract tests, auth-transition mutation inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Batch 19: Detail and editor search ownership

- Collection item search now invalidates older debounced and in-flight requests whenever its query changes or the panel disappears.
- A late collection search response can no longer repopulate results after the query is changed, cleared, or dismissed.
- The story sticker picker now separates query-reset ownership from cursor pagination ownership.
- Changing a sticker query during an active request immediately permits the replacement request, while older pages cannot replace or append into the new query.
- Preserved collection add behavior, search debounce timing, sticker browsing, load-more pagination, error UI, and all visible layouts.
- Verified with 8 routing contract tests, query/pagination ownership inspection, diff-integrity checks, and complete unsigned dual-architecture iOS Simulator builds after each change.

### Batch 20: Secondary feeds and playback lifecycle

- Reaction/post refreshes now use latest-request ownership, preventing an older initial or notification-triggered load from replacing a newer feed.
- Periodic episode progress writes are bound to the episode that created the timer instead of mutable current-navigation state.
- Audited video, episode, microdrama, Shorts, and player-chrome lifecycle paths for periodic observers, end observers, timers, autoplay tasks, and teardown symmetry.
- Verified that image memory/disk caches, Shorts player/asset pools, memory-pressure eviction, and startup warmups are bounded and cancellable; no behavior-changing cache rewrite was warranted.
- Preserved post animations, inserted-post behavior, playback handoff, mini-player/fullscreen transitions, ads, autoplay, progress cadence, and all visible UI.
- Verified with 8 routing contract tests, lifecycle/cache invariant inspection, a clean unsigned dual-architecture iOS Simulator build, and an iPhone 17 Pro Simulator install/launch smoke test with a live app process and no fatal startup log entries.

### Corrective QA: Shorts single-pager refresh

- Pull-to-refresh no longer empties the live Shorts array while its UIKit pager still owns the active refresh gesture.
- The existing pager and current playback remain mounted until the replacement response is ready, then the feed data is swapped atomically.
- Prevented the outgoing refresh-control pager and newly created feed pager from appearing together during downward overscroll.
- A failed refresh preserves the current playable feed and uses the existing non-blocking pagination error banner.
- Preserved feed reseeding, ad-state reset, curation slots, current-item selection, playback configuration, and refresh-control behavior.
- Verified with 8 routing contract tests, pager-lifecycle inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.

### Corrective QA: Shorts cache-first revalidation

- Restored in-memory and prewarmed Shorts feeds still render immediately for zero-wait playback.
- Cached startup feeds now trigger a silent network revalidation instead of becoming the final feed until manual refresh.
- Revalidation explicitly bypasses both the five-minute prewarm cache and the shared 45-second Shorts API response cache.
- The existing feed seed is retained for continuity, and the current Short remains selected when it still exists in the refreshed response.
- Revalidation publishes only while the original feed generation, feed tab, and seed still own the screen; failure leaves cached playback untouched.
- Preserved manual refresh reseeding, pagination, curation, ads, playback prewarming, and visible UI.
- Verified with 8 routing contract tests, cache/ownership invariant inspection, diff-integrity checks, and a complete unsigned dual-architecture iOS Simulator build.
