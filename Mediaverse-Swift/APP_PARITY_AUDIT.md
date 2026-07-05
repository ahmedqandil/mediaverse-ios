# Mediaverse iOS Full-App Parity Audit

This ledger tracks the feature-by-feature audit against:
- `IOS_PORTING_DIRECTIVE.md`
- `/Users/ahmedqandil/Dropbox/Mac (2)/Claude/Projects/Mediaverse/docs`
- `/Users/ahmedqandil/Dropbox/Mac (2)/mediaverse`

## Workflow For Each Feature
1. Read the relevant documentation and web implementation.
2. Map backend routes, payloads, permissions, states, analytics, and navigation.
3. Audit the current Swift implementation.
4. Fix parity gaps without changing backend unless explicitly approved.
5. Run design/style parity check for UI changes.
6. Run Xcode diagnostics and a build after meaningful edits.

## Feature Order

| # | Feature | Docs | Swift Surface | Status |
|---|---|---|---|---|
| 1 | Auth & Session | `05-auth.md` | `LoginView`, `SplashView`, `AuthManager`, `SessionStorage`, `APIClient` | Audited; Fixes Applied |
| 2 | Backstage Upload | `03`, `04` | `UploadView`, Profile entry, upload API helpers | Audited; Native Contract Complete; Backend-dependent Blob gap |
| 3 | Home Feed | `06` | `HomeView`, feed models/API | Audited; Fix Applied |
| 4 | Watch Player | `07`, `12` | `VideoWatchView`, `EpisodeWatchView`, player subviews | Audited; Fixes Applied |
| 5 | Shorts | `06`, `07`, `12` | `ShortsView` | Audited; Fixes Applied |
| 6 | Microdramas | `08` | `MicrodramaShowView`, `MicrodramaWatchView` | Audited; Fixes Applied |
| 7 | Search | `10` | `SearchView` | Audited; Fixes Applied |
| 8 | Channels & Shows | `11`, `02` | `ChannelView`, `ShowView`, browse views | Audited; Fixes Applied |
| 9 | Collections & Playlists | `09` | `CollectionsView`, `PlaylistsView`, `PlaylistDetailView`, save sheet | Audited; Fixes Applied |
| 10 | Social & Notifications | `12` | comments, posts, moment likes, notifications | Audited; Fixes Applied |
| 11 | Profile, History, Notifications Polish | `05`, `09`, `12` | profile/history/notification surfaces | Audited; Fixes Applied |
| 12 | Browse & Discovery | `06`, `10`, `11` | `BrowseView`, category browse pages | Audited; Fixes Applied |
| 13 | Billing & Entitlements | `01`, `07`, `08` | entitlement/checkout surfaces | Audited; Fixes Applied |
| 14 | Scheduling | `02`, `11` | coming-soon/availability surfaces | Audited; Fix Applied |
| 15 | Network Studio/Admin | `13`, `03` | upload and studio root | In Progress |

## Current Notes
- Continue one feature at a time.
- Destination/playlist controls in creator/backstage flows must use lookup/search controls when web does.
- UI work requires a mobile web design/style parity check before completion.

## App-Wide Viewer/API Re-Audit — 2026-07-05

### Scope
- User requested a non-Studio pass for loading failures, breakages, API issues, and missing mobile-web parity.
- Audited high-traffic viewer-facing routes and native surfaces: Home/Continue Watching, Shorts follow, Profile load/edit, watch/social routes, microdramas, collections/playlists, channel/show browse/detail, auth/context/notifications.

### Fixes Applied
- Shorts follow now uses channel handles for `/api/channels/[handle]/subscribe`; previous code used channel ids and could silently fail.
- Continue Watching now decodes `/api/progress` compact nested video/episode payloads instead of requiring full feed/watch navigation models.
- Profile now decodes the live `/api/me/profile` `{ user, ... }` response and profile edits use backend-supported `PATCH /api/me/profile`.
- Studio response wrappers were changed from `Codable` to `Decodable` only to keep the app compiling after the safer Studio decoder; no Studio feature work was continued in this pass.

### Design/Style Parity
- No visible layout changes were introduced.
- Existing mobile-web-mirrored surfaces remain unchanged:
  - Home Continue Watching cards.
  - Shorts full-screen player/action rail.
  - Profile edit sheet.

### Validation
- Live diagnostics clean for touched files.
- Full Xcode build passed.

## Feature 1 — Auth & Session

### Source Audit
- Docs say mobile auth returns `accessToken` and APIs accept `Authorization: Bearer`.
- Actual backend currently returns `sessionToken` from `/api/auth/mobile/verify` and `/api/auth/mobile/google`.
- Actual `/api/auth/session` and `getSessionUserId()` read NextAuth cookies, not bearer headers.
- Therefore the current Swift cookie injection is correct for the live backend contract.

### Fixes Applied
- Preserved `/api/auth/magic` `debug_url` response for dev/no-email mode instead of dropping it.
- Added `AuthManager.magicLinkDebugURL`.
- Reworked `LoginView` to mirror mobile web `/auth/signin`:
  - WeStreem branding and subtitle.
  - Rounded sign-in card.
  - Google button first, then divider, then email form.
  - Uppercase `EMAIL ADDRESS` label.
  - `Continue with email ->` copy.
  - Check-inbox card with email highlight, 24-hour expiry/spam-folder copy, and debug link block.

### Validation
- Live Xcode diagnostics clean for `LoginView`, `AuthManager`, `APIClient`, and `SessionStorage`.
- Full Xcode build passed.

## Feature 2 — Backstage Upload

### Source Audit
- Web source: `/app/upload/page.tsx`.
- Backend routes audited: `/api/me/upload-contexts`, `/api/video/cf-stream-upload`, `/api/upload`, `/api/video/[id]/stream-status`, channel/show backstage videos, show episodes.
- Docs source: `03-backstage-admin.md`, `04-content-pipeline.md`.

### Fixes Applied
- Added native upload entry and full upload flow.
- Matched Cloudflare Stream TUS upload, upload limits, record creation, status polling, playlist assignment, and short link fields.
- Matched mobile web visual structure: video file section, thumbnail section, content type, destination lookup, playlist lookup, details, link-to, sticky compact submit.
- Destination and playlist now use lookup/search controls, not flat pickers.

### Known Backend-Dependent Gap
- Web selected-frame thumbnail and fallback Blob video upload use browser-only `@vercel/blob/client`.
- Existing `/api/video/local-upload` is admin-only local filesystem storage and does not mirror `/app/upload`.
- Exact parity requires an approved backend-native upload endpoint or a documented native Blob client contract.

### Validation
- Design/style parity audit completed against `/app/upload/page.tsx`.
- Full Xcode build passed after lookup fixes.

## Feature 3 — Home Feed

### Source Audit
- Docs source: `06-feed-home.md`.
- Web source: `/src/app/page.tsx`, `/src/components/HomeFeedClient.tsx`.
- Swift source: `HomeView`, `HomeFeedConfig`, feed/continue/carousel API helpers.

### Findings
- Swift correctly reads `/api/feed-config` and uses `mobileCarouselEvery`, `mobileCarouselCount`, and configured `carouselSlots`.
- Swift correctly interleaves carousels after every configured number of feed videos.
- Swift fetches feed, continue watching, shows, shorts, microdramas, and derives channels/videos carousel data.
- Backend/docs mismatch noted: docs say channels carousel derives from feed items; current web server fetches channels separately. Swift currently follows docs/iOS design and derives from feed.
- Parity gap found: web renders remaining carousel slots after the video feed is exhausted; Swift dropped those if not enough videos were present to interleave all slots.

### Fixes Applied
- Updated `HomeView.renderItems` to append remaining configured carousel slots when `cursor == nil`, matching web `remainingSlots` behavior.

### Design/Style Parity
- No major visual rewrite in this pass.
- Verified the behavior-level parity change against `HomeFeedClient.tsx`.

### Validation
- Live Xcode diagnostics clean for `HomeView`, `Models`, and `APIClient`.
- Full Xcode build passed before starting Watch Player.

## Feature 4 — Watch Player

### Source Audit
- Docs source: `07-watch-player.md`, social portions of `12-social.md`.
- Web source: `/src/app/watch/WatchClient.tsx`, `/src/components/VideoPlayer.tsx`, watch page server components, `/api/progress`, `/api/videos/[id]/markers`, `/api/episodes/[id]/markers`.
- Swift source: `VideoWatchView`, `EpisodeWatchView`, `MomentLikeBarView`, `PostSectionView`, progress API/model helpers.

### Findings
- Backend `POST /api/progress` requires `{ videoId? | episodeId?, seconds, percent }`.
- Backend `GET /api/progress` returns a raw array for Continue Watching, while single item restore is available at `?videoId=` or `?episodeId=`.
- Swift was posting `{ videoId, progress }`, and episode progress incorrectly sent an episode id through the `videoId` field.
- Player markers exist on web and backend, visible for 20 seconds at each marker timestamp, but were absent from iOS playback.
- `/api/episodes/[id]` already mirrors the web SSR entitlement gate by returning `paywallInfo` and stripping `videoUrl` for locked content. Swift was additionally relying on `/api/entitlement/check`, which returns 401 for signed-out users and could leave signed-out AVOD playback stuck on a spinner.

### Fixes Applied
- Updated `ProgressItem` to decode live backend fields `seconds` and `percent`, while preserving `item.progress` as a compatibility computed property.
- Made `ContinueWatchingResponse` decode both the live raw-array response and the older `{ items }` shape.
- Added single-item progress fetch helpers for video and episode restore.
- Updated video and episode watch progress writes to send exact `seconds` and `percent`.
- Fixed episode progress to use `episodeId`, not `videoId`.
- Added `PlayerMarker` model and video/episode marker API helpers.
- Added top-right timed marker pill overlays to video and episode players:
  - 20-second display window.
  - Dismiss action.
  - Native navigation for internal watch/show/channel/playlist links.
  - External URL fallback through `openURL`.
- Updated episode playback access logic to trust the episode detail response first:
  - `paywallInfo` + no `videoUrl` shows the paywall.
  - no `paywallInfo` + `videoUrl` plays, including signed-out AVOD.
  - authenticated `/api/entitlement/check` can still deny access.

### Design/Style Parity
- Marker pill placement, dark blurred/pill styling, accent icon, and dismiss affordance mirror mobile web while avoiding AVKit bottom controls.
- Existing AVKit player controls remain native iOS standard; custom web-only speed/quality/clip controls remain a separate future parity area.
- Runtime PPV play recording route exists at `/api/me/entitlements/check`, but current mobile web `WatchClient` does not call it directly in the audited code path. This is recorded as a parity gap to resolve alongside backend/web behavior, not invented in iOS alone.

### Validation
- Live Xcode diagnostics clean for `Models`, `APIClient`, `VideoWatchView`, and `EpisodeWatchView`.
- Full Xcode build passed after Watch fixes.
- Full Xcode build passed again after episode entitlement fallback fix.

## Feature 5 — Shorts

### Source Audit
- Docs source: `06-feed-home.md`, `07-watch-player.md`, `12-social.md`.
- Web source: `/src/app/shorts/page.tsx`, `/src/app/shorts/ShortsPlayer.tsx`, `/src/app/api/shorts/route.ts`, channel subscribe route.
- Swift source: `ShortsView`, `Short`/`ShortsResponse`, `APIClient.fetchShorts`, channel follow helpers.

### Findings
- Backend `/api/shorts` returns `{ shorts, nextCursor, reason }`; `reason` is used for empty Following feed states: `not_logged_in` and `no_follows`.
- Swift dropped `reason`, so it could not exactly render backend-driven empty states.
- Web fetches follow status for each card before rendering the Follow button state. Swift initialized every short as not-following and only toggled optimistically.
- Channel subscribe endpoint accepts either channel id or handle, so iOS can use the existing channel id from `/api/shorts`.
- Backend `/api/shorts` currently does not include a `show` owner object, while `/shorts/page.tsx` can build show-owned fallback owners server-side. Native cannot fully mirror show-owned short owner/follow fallback without backend response support.

### Fixes Applied
- Added `ShortsResponse.reason`.
- Wired root Shorts empty state to backend `reason`, including `no_follows`.
- URL-encoded `feed` and `cursor` in `fetchShorts`.
- Added per-card follow-status loading through `/api/channels/{id}/subscribe`.
- Updated follow toggling to use the typed `toggleChannelFollow` response instead of raw `postEmpty`.

### Design/Style Parity
- Mobile structure remains aligned with web: full-screen vertical pager, top feed tabs, top-right mute, right action rail, bottom metadata, linked clip/episode cards, bottom progress bar, and comments drawer.
- Changes in this pass were behavior/state parity changes; no visual redesign was introduced.

### Known Gap
- Show-owned shorts in native iOS need `/api/shorts` to include `show` data for exact web fallback owner/follow behavior. Backend was not changed per directive.

### Validation
- Live Xcode diagnostics clean for `ShortsView`, `Models`, and `APIClient`.
- Full Xcode build passed after Shorts fixes.

## Feature 6 — Microdramas

### Source Audit
- Docs source: `08-microdramas.md`.
- Web source: `/src/app/microdramas/[showId]/MicrodramaShowClient.tsx`, `/src/components/MicrodramaPlayer.tsx`, `/api/microdrama/[showId]/episodes`, `/api/microdrama/ad-unlock`.
- Swift source: `MicrodramaShowView`, `MicrodramaWatchView`, microdrama models/API helpers.

### Findings
- Backend redacts `videoUrl` for locked episodes and restores it after a granted ad unlock.
- Web episode rows navigate to `/microdramas/watch/{showId}?ep={episodeNumber}`.
- Swift episode rows navigated to the series watch route without the selected episode number, so tapping any playable row could start at episode 1.
- `EpisodePlayerSlide` created and stored `AVPlayer` from inside `body`, which mutates SwiftUI state during render and can cause runtime instability.
- Ad unlock inside the watch player inserted a local granted id but did not reload the episode list, so the newly unlocked episode still lacked the backend-returned `videoUrl`.

### Fixes Applied
- Episode list rows now route through `AppRoute.microdramaWatchEp(showId, episodeNumber)`.
- Watch player load now sets `currentIdx` from `startEpisodeNumber`.
- Removed AVPlayer state mutation from slide rendering.
- Added active-slide player lifecycle:
  - only the active slide creates/plays an `AVPlayer`
  - inactive slides pause
  - reactivated slides resume from the start
  - disappearing slides release the player
- After ad unlock in the watch player, the app reloads `/api/microdrama/{showId}/episodes` and keeps the user on the unlocked episode so the unredacted `videoUrl` is available.

### Design/Style Parity
- Selected episode behavior now matches the mobile web `?ep=` navigation contract.
- The vertical player now follows the same active-card model as web: only the active episode plays.
- No unrelated visual redesign was introduced.

### Validation
- Live Xcode diagnostics clean for `MicrodramaShowView`, `MicrodramaWatchView`, `Models`, and `APIClient`.
- Full Xcode build passed after Microdrama fixes.

## Feature 7 — Search

### Source Audit
- Docs source: `10-search.md`.
- Web/backend source: `/src/app/search/page.tsx`, `/api/search`, `/api/search/suggest`.
- Swift source: `SearchView`, search models/API helpers.

### Findings
- Backend trims `q` and requires at least 2 characters.
- Suggest items include `href` deep links and are intended to point directly to channels, shows, videos/shorts, and episodes.
- Swift used raw query length, so whitespace could trigger requests that backend treats as empty.
- Swift suggestion taps replaced the query with the suggestion title and ran full search instead of navigating to the suggested target.

### Fixes Applied
- Search and suggest calls now trim whitespace before min-length checks and requests.
- Suggestion taps now parse `href` and navigate natively when possible:
  - `/watch/{id}` → video watch
  - `/watch/episode/{id}` → episode watch
  - `/shows/{id}` → show
  - `/channel/{handle}` and `/channels/{handle}` → channel
  - playlist and microdrama links where applicable
- Unknown suggestion hrefs fall back to title-based full search.

### Design/Style Parity
- Preserved existing native compact search layout.
- Behavior now matches web suggest semantics by treating suggestions as navigable entities, not just query replacements.

### Validation
- Live Xcode diagnostics clean for `SearchView`, `Models`, and `APIClient`.
- Full Xcode build passed after Search fixes.

## Feature 8 — Channels & Shows

### Source Audit
- Docs source: `11-channels-shows.md`.
- Web source: `/src/app/channel/[handle]/ChannelClient.tsx`, `/src/app/shows/[id]/ShowClient.tsx`.
- Backend/API source: `/api/channels/[handle]`, `/api/channels/[handle]/playlists`, `/api/shows/[id]`, `/api/shows/[id]/playlists`.
- Swift source: `ChannelView`, `ShowView`, `Models`, `APIClient`.

### Findings
- Channel and show playlist cards on web are links. If a playlist has an item, web opens the first item directly (`/watch/{id}?list={playlistId}` or shorts equivalent); otherwise it opens `/playlist/{id}`.
- Native channel/show playlist cards were static, so public playlists were visible but not actionable.
- Show hero CTA used the first episode id even when the backend had stripped `videoUrl` for entitlement or the episode was still coming soon.
- Show episode rows always navigated to watch, even when web disables unavailable rows and shows subscribe/rent lock affordances for gated content.
- `/api/channels/[handle]` is handle-based; subscribe accepts handle or id for compatibility.

### Fixes Applied
- Added shared `ChannelPlaylist.primaryRoute`.
- Channel playlist cards now navigate to the first playlist item when present and fall back to playlist detail when empty.
- Show playlist cards now use the same navigation behavior.
- Show hero Watch CTA now uses the first episode with backend-present `videoUrl` and not `comingSoon`.
- Show episode rows now:
  - navigate only when backend says the episode is playable
  - remain visible but non-navigable for coming soon/locked items
  - show a lock overlay and subscribe/rent CTA for SVOD/PPV gated episodes
  - open the web show page for checkout, matching the current web fallback path

### Design/Style Parity
- Playlist card visual layout remains unchanged while restoring web tap behavior.
- Locked episode rows preserve the existing compact native row layout and add only the web-equivalent lock state/copy.
- No unrelated visual redesign was introduced.

### Known Gap
- Native routes do not yet carry playlist context (`?list=`), so continuous list playback parity is incomplete.
- Native has no list-aware shorts route equivalent to `/shorts/{id}?list={playlistId}`. The current closest native route opens the first item through the existing video watch route.

### Validation
- Live Xcode diagnostics clean for `ChannelView` and `ShowView`.
- Full Xcode build passed after Channels & Shows fixes.

## Feature 9 — Collections & Playlists

### Source Audit
- Docs source: `09-collections-playlists.md`.
- Web source: `/src/app/collections/page.tsx`, `/src/app/collections/[id]/page.tsx`, `/src/app/playlists/page.tsx`, `/src/app/playlist/[id]/page.tsx`.
- Backend/API source: `/api/collections`, `/api/collections/[id]`, `/api/collections/[id]/items`, `/api/collections/[id]/follow`, `/api/playlists`, `/api/playlists/[id]`, playlist item/reorder routes.
- Swift source: `CollectionsView`, `CollectionDetailView`, `PlaylistsView`, `PlaylistDetailView`, `Models`, `APIClient`, `AppRoute`.

### Findings
- Web collections have two list tabs: owner collections and public community collections.
- Web collection cards navigate to `/collections/[id]`; native collection cards were static.
- Web collection detail supports public follow toggle, owner add/search by collection type, item links, and owner remove.
- Native had no collection detail route/screen.
- Playlist owner/detail views were already substantially implemented. Native removal additionally reorders after delete, while web delete only removes the item. Backend reorder accepts `order`; current extra call is harmless but not required.
- Public playlist detail is still backend-limited: `/api/playlists/[id]` requires owner access.

### Fixes Applied
- Added `AppRoute.collection` and root/search navigation support.
- Added backend models and API helpers for collection detail, public collections, follow toggle, collection update, typed add, and item removal.
- Added native `CollectionDetailView`:
  - header metadata and public/private badge
  - community follow/unfollow
  - owner-only typed add/search panel
  - typed grids for shows, clips, and shorts
  - item links to native show/video watch routes
  - owner remove buttons with optimistic rollback
- Updated `CollectionsView`:
  - My Collections / Communities tabs
  - loads `/api/collections` and `/api/collections?public=true`
  - cards navigate to detail
  - public cards show creator metadata
  - owner cards expose delete action
- Updated collection thumbnails to match web aspect logic: shows use poster ratio, shorts use vertical ratio, clips use video ratio.

### Design/Style Parity
- Collection list now mirrors the mobile web hierarchy: title/action area, tab strip, card grid, visibility badges, creator/public metadata.
- Collection detail follows the mobile web information order: title/description/actions, metadata row, owner add lookup, typed item grid.
- Native controls use SwiftUI idioms while preserving web colors, spacing density, badges, and typed aspect ratios.

### Known Gap
- Collection community discussion uses web `CommentThread`; there is no native collection comment surface yet. Native shows a discussion placeholder rather than inventing a backend contract.
- Collection edit modal parity is partial: owner delete is available from the list, while full edit fields remain to be added natively.
- Playlist list playback still lacks `?list=` route context and shorts-list routing, as recorded in Feature 8.

### Validation
- Live Xcode diagnostics clean for `CollectionDetailView`, `CollectionsView`, `Models`, `APIClient`, `MainTabView`, `SearchView`, and `AppRoute`.
- Full Xcode build passed after Collections & Playlists fixes.

## Feature 10 — Social

### Source Audit
- Docs source: `12-social.md`.
- Web source: `/src/app/following/page.tsx`, `/src/app/notifications/page.tsx`, `/src/components/PostSection.tsx`, watch client social hooks.
- Backend/API source: comments, likes/dislikes, moment likes, posts, post comments, notifications, following feed routes.
- Swift source: `FollowingView`, `NotificationsView`, `PostSectionView`, `MomentLikeBarView`, watch views, social models/API helpers.

### Findings
- Actual moment-like API returns `buckets` and `userLikedSeconds`, matching Swift. The docs reference to `counts`/`userLikes` is stale.
- Notifications web rows navigate when `linkUrl` exists. Native rows were display-only.
- Notifications backend supports `PUT /api/notifications` mark-all-read scoped to active context; native behavior matches web by fetching first and marking read after display.
- Native post share used a hardcoded external URL instead of the web-equivalent watch URL with clip query params.
- Following feed tabs and content grouping already match the web route and `/api/subscriptions/feed` contract.

### Fixes Applied
- Notification rows now open `linkUrl`:
  - known internal links route natively
  - unknown/external links open through `openURL`
  - row chevron indicates navigable notifications
- Notification route parsing now handles videos, episodes, shows, channels, playlists, collections, and microdramas.
- Post share now uses `C.baseURL` and the current target:
  - videos: `/watch/{id}?t={markIn}&out={markOut}`
  - episodes: `/watch/episode/{id}?t={markIn}&out={markOut}`

### Design/Style Parity
- Notification rows keep the native card styling while restoring web tap behavior for linked notifications.
- Post cards keep the compact mobile layout and now share the same URL semantics as web.

### Known Gap
- Native top-level watch comments still fetch only the initial comment set; reply expansion is stronger in post comments than in the generic watch comments section.
- Native does not yet expose a create-clip-post control from the player timeline; it displays and interacts with existing posts.

### Validation
- Live Xcode diagnostics clean for `NotificationsView`, `PostSectionView`, and `FollowingView`.
- Full Xcode build passed after Social fixes.

## Feature 11 — Profile, History, Notifications Polish

### Source Audit
- Web source: `/src/app/profile/page.tsx`, `/src/app/history/page.tsx`, profile/history/notification API routes.
- Swift source: `ProfileView`, `WatchHistoryView`, `NotificationsView`, `ContextSwitcherView`, profile/history models/API helpers.

### Findings
- Native profile had two dead rows: `Edit Profile` and `Collections`.
- Web profile supports broad profile editing including avatar/banner Blob uploads; native currently has only the documented `/api/me/profile` helper for `name` and `bio`.
- Native watch history already matches the core history API behavior: list rows route to video/episode, and clear-all calls `DELETE /api/history`.

### Fixes Applied
- Wired `Collections` profile row to native `CollectionsView`.
- Added native `EditProfileSheet` for the existing backend-supported fields:
  - display name
  - bio
  - save via `APIClient.updateProfile`
- Profile refreshes the in-memory header after save.

### Design/Style Parity
- The edit profile sheet follows the existing native form style and web dark visual language.
- The fix restores expected profile-row interactivity without changing unrelated profile layout.

### Known Gap
- Full web profile edit parity still needs a native-supported Blob/image upload contract for avatar/banner and additional profile fields (`location`, websites). Backend was not changed.

### Validation
- Live Xcode diagnostics clean for `ProfileView`, `WatchHistoryView`, and `NotificationsView`.
- Full Xcode build passed after Profile/History polish.

## Feature 12 — Browse & Discovery

### Source Audit
- Docs source: `06-feed-home.md`, `10-search.md`, `11-channels-shows.md`.
- Web source: `/src/app/channels/page.tsx`, `/src/components/ChannelCard.tsx`, `/src/app/movies/page.tsx`, `/src/app/shows/page.tsx`, `/src/app/shows/ShowsPageClient.tsx`.
- Backend/API source: `/api/channels`, `/api/channels/[handle]/subscribe`, `/api/shows`, `/api/search`.
- Swift source: `BrowseView`, `ChannelsBrowseView`, `ShowsBrowseView`, `MoviesBrowseView`, `MicrodramasBrowseView`, `APIClient`, `Models`.

### Findings
- Web has a dedicated `/channels` discovery route; native Browse had no Channels entry or full channels browse screen.
- Web channel browse filters `status !== "inactive"` and searches by name/handle against `/api/channels`.
- Web channel cards are full cards with banner, avatar, name/handle, verification, description, counts, and authenticated follow control.
- `BrowseView` created a nested `NavigationStack` inside the tab stack, which could break value-based route navigation from child browse pages.
- Movies/shows category pages still need deeper parity follow-up against the web server/client split and `/api/shows` filtering.

### Fixes Applied
- Added `ChannelBrowseCard` model and `APIClient.fetchChannels()`.
- Added native `ChannelsBrowseView`:
  - `/api/channels` loading
  - inactive filtering
  - name/handle search
  - loading skeletons
  - empty states matching query/no-query cases
  - full channel cards with banner, avatar, verified badge, description, follower/video counts, and follow/following control for authenticated users
  - native navigation to `ChannelView` by handle
- Added Channels row to `BrowseView`.
- Removed the nested `NavigationStack` from `BrowseView` so route-based links in browse subpages use the tab-level `navigationDestination`.
- Expanded `ShowBrowseCard` with web-used hero/card fields: `description`, `bannerUrl`, `language`, and `contentRating`.
- Updated `APIClient.fetchShowsBrowse` to use `/api/shows?take=80` with optional `q` and `genre`, preserving the backend visibility and geo filtering used by the web route.
- Rebuilt `ShowsBrowseView` to mirror the web `/shows` client:
  - full-width featured hero
  - Browse / TV Shows & Series header
  - rounded search input with clear action
  - submitted search-results mode
  - New & Popular carousel
  - generated genre carousels
  - poster cards with rating and entitlement badges
  - native show navigation
- Added `movieDuration` decoding to `ShowBrowseCard` from the nested first episode duration shape used by web `/movies`.
- Updated `APIClient.fetchMoviesBrowse` to use `/api/shows?take=80` with optional `q` and `genre`, then filter the same web movie types: `movie`, `documentary`, and `special`.
- Rebuilt `MoviesBrowseView` to mirror web `/movies`:
  - `Watch · Movies` eyebrow and `Movies & Films` header
  - horizontal genre pills
  - dense 3-column poster grid
  - content rating and entitlement overlays
  - fallback poster state
  - year, duration, and genre metadata
  - native show navigation
- Rebuilt `MicrodramasBrowseView` to mirror web `/microdramas`:
  - page header and subtitle
  - hero with description and action pills
  - skeleton loading structure
  - empty state copy
  - Trending and New Releases rows
  - duplicate-safe genre rows
  - 9:16 poster cards with season-count badge
  - native microdrama detail/watch navigation

### Design/Style Parity
- Channels browse now mirrors the mobile web hierarchy: large title from navigation, compact rounded search input, one-column mobile full-card grid, banner/avatar overlap, stats row, and follow pill.
- Native cards preserve the web visual structure and spacing while omitting web-only hover overlays.
- Shows browse now mirrors the mobile web hierarchy: full-bleed hero first, compact browse/search header, search-results grid when submitted, horizontal poster carousels for New & Popular and genres, and compact poster metadata.
- Movies browse now mirrors the mobile web hierarchy: compact category header, scrollable genre pills, dense poster grid, poster fallback, rating badge, entitlement badge, and compact metadata row.
- Microdramas browse now mirrors the mobile web hierarchy: header/subtitle, rounded hero, section rows, horizontal 9:16 posters, season-count badge, and empty/loading states.

### Known Gap
- Shows page admin configuration (`showsPageConfig`) is currently server-rendered in the web page and has no public iOS API. Native derives New & Popular and genre rows from `/api/shows` rather than reading the admin row labels/order directly.
- Movies web SSR receives user access summary and can pass exact `hasAccess` into `EntitlementBadge`. Native shows the same badge type but does not yet compute access state for the browse grid.
- Web hover-only poster effects are intentionally omitted on native touch surfaces while preserving tap targets and visible metadata.

### Validation
- Live Xcode diagnostics clean for `ChannelsBrowseView`, `BrowseView`, `Models`, and `APIClient`.
- Full Xcode build passed after Browse channels fixes: `/var/folders/bt/mrgclqgx5wjgh1s_0rs3njrh0000gn/T/ActionArtifacts/840B781E-C1E9-4E19-A01D-BA5500D95EC5/BuildProject/BuildProject-Log-20260705-142506.txt`.
- Live Xcode diagnostics clean for `ShowsBrowseView`, `MoviesBrowseView`, `Models`, and `APIClient`.
- Full Xcode build passed after Shows browse fixes: `/var/folders/bt/mrgclqgx5wjgh1s_0rs3njrh0000gn/T/ActionArtifacts/840B781E-C1E9-4E19-A01D-BA5500D95EC5/BuildProject/BuildProject-Log-20260705-142813.txt`.
- Live Xcode diagnostics clean for `MoviesBrowseView`, `ShowsBrowseView`, `Models`, and `APIClient`.
- Full Xcode build passed after Movies browse fixes: `/var/folders/bt/mrgclqgx5wjgh1s_0rs3njrh0000gn/T/ActionArtifacts/840B781E-C1E9-4E19-A01D-BA5500D95EC5/BuildProject/BuildProject-Log-20260705-143010.txt`.
- Live Xcode diagnostics clean for `MicrodramasBrowseView`, `BrowseView`, and `ChannelsBrowseView`.
- Full Xcode build passed after Microdramas browse fixes: `/var/folders/bt/mrgclqgx5wjgh1s_0rs3njrh0000gn/T/ActionArtifacts/840B781E-C1E9-4E19-A01D-BA5500D95EC5/BuildProject/BuildProject-Log-20260705-143200.txt`.

## Feature 13 — Billing & Entitlements

### Source Audit
- Docs source: `01-billing-budgeting.md`, watch and microdrama entitlement notes from `07-watch-player.md` and `08-microdramas.md`.
- Web source: `/src/components/CheckoutModal.tsx`, `/src/app/shows/[id]/ShowClient.tsx`, `/src/app/watch/WatchClient.tsx`.
- Backend/API source: `/api/checkout/svod`, `/api/checkout/ppv`, `/api/me/entitlements/check`, episode/show paywall payloads.
- Swift source: `ShowView`, `EpisodeWatchView`, `APIClient`, `Models`.

### Findings
- Native `APIClient` had checkout helpers, but `ShowView` still opened the web show page for Subscribe/Rent actions.
- Episode watch paywall displayed lock/product/price but did not expose the web-equivalent `Rent now` / `Subscribe to watch` CTA.
- `CheckoutResponse` did not decode `networkSubscriptionId` or `redirectUrl`, both part of the checkout contract for subscription settlement and future real providers.
- Actual backend checkout routes resolve country from request headers, not request body, so the native request body should remain `{ productId, networkId, seasonId?, episodeId? }`.

### Fixes Applied
- Expanded `CheckoutResponse` to decode `networkSubscriptionId` and `redirectUrl`.
- Added native show checkout flow:
  - show hero Subscribe/Rent opens a native checkout sheet
  - locked episode-row CTA opens the same native checkout flow
  - PPV passes the selected/first season id, matching the web fallback rule
  - checkout success reloads the show, matching web `router.refresh()`
  - provider redirects open externally through `openURL`
  - provider `clientSecret` without native confirmation shows a clear limitation message
- Added episode watch paywall checkout:
  - overlay now includes `Rent now` / `Subscribe to watch`
  - calls `/api/checkout/ppv` or `/api/checkout/svod` from `paywallInfo`
  - success reloads the episode so the backend returns the unredacted `videoUrl`

### Design/Style Parity
- Show checkout sheet mirrors the web modal states and hierarchy with native presentation: colored top strip, product icon, Subscribe/Rent eyebrow, product name, price/cycle/scope rows, confirm/cancel actions.
- Episode watch paywall now mirrors web action semantics while keeping the native AVPlayer overlay layout.

### Known Gap
- Real provider confirmation with `clientSecret` is not implemented natively. Current backend uses the placeholder provider and auto-approves; when a real provider is enabled, iOS needs a native payment confirmation surface or hosted redirect contract.
- Web plan picker for multiple SVOD products is not fully replicated; native uses the first product currently exposed by the show CTA, matching the previous native behavior but not full web parity.
- Browse entitlement badges do not yet compute exact user `hasAccess` state server-side like web SSR movie cards.

### Validation
- Live Xcode diagnostics clean for `ShowView`, `EpisodeWatchView`, `Models`, and `APIClient`.
- Full Xcode build passed after Billing & Entitlements fixes: `/var/folders/bt/mrgclqgx5wjgh1s_0rs3njrh0000gn/T/ActionArtifacts/840B781E-C1E9-4E19-A01D-BA5500D95EC5/BuildProject/BuildProject-Log-20260705-143610.txt`.

## Feature 14 — Scheduling

### Source Audit
- Docs source: `02-scheduling.md`.
- Web source: `/src/app/shows/[id]/ShowClient.tsx`, `/src/app/watch/episode/[id]/page.tsx`, `/src/app/watch/WatchClient.tsx`.
- Backend/API source: show/episode schedule payloads, schedule windows, cron unlock behavior.
- Swift source: `ShowView`, `ShowEpisodeItem`.

### Findings
- Scheduling and rights validation are backend-owned; native should consume `comingSoon`, `videoUrl`, `isPlayable`, and schedule windows rather than reimplementing rights resolution.
- Docs explicitly note `comingSoon` is cron-updated and may lag after `premiereAt`.
- Web compensates for this by computing `isDue = premiereAt <= now` and treating `comingSoon && !isDue` as the true coming-soon state.
- Native episode rows used raw `ep.comingSoon`, so an episode could still show Coming Soon after its premiere window was already due.

### Fixes Applied
- Updated `EpisodeRowView` schedule logic:
  - selects premiere date using web priority: worldwide window, then first window
  - parses ISO dates with and without fractional seconds
  - computes `isComingSoon = ep.comingSoon && !isPremiereDue`
  - computes row availability from `isPlayable` or backend-present `videoUrl`, blocked only while true coming-soon
  - duration, overlay, opacity, navigation, and premiere label now use the computed state

### Design/Style Parity
- Coming Soon overlay and premiere label remain visually aligned with the existing native row design while matching the web behavior rules.
- No native rights-validation UI was invented; backend schedule decisions remain authoritative.

### Known Gap
- Season-level schedule metadata is not fully exposed in the current native model, so hero-level release date badges from the web show page remain limited to episode-row premiere labels.

### Validation
- Live Xcode diagnostics clean for `ShowView` and `Models`.
- Full Xcode build passed after Scheduling fix: `/var/folders/bt/mrgclqgx5wjgh1s_0rs3njrh0000gn/T/ActionArtifacts/840B781E-C1E9-4E19-A01D-BA5500D95EC5/BuildProject/BuildProject-Log-20260705-143753.txt`.

## Feature 15 — Network Studio/Admin

### Source Audit
- Docs source: `13-network-studio.md`, `03-backstage-admin.md`.
- Web source: `/src/app/backstage/studio/page.tsx`, `/src/app/backstage/studio/productions/page.tsx`.
- Backend/API source: `/api/backstage/studio/productions`.
- Swift source: `ProfileView`, `StudioView`, `Models`, `APIClient`, existing `UploadView`.

### Findings
- Native only exposed Upload Content from the creator/backstage surface.
- Network Studio is a large missing native area: productions, scenes, shots, cast, jobs, pipeline streaming, costs, cancellation, and generated assets.
- The safest first native slice is the Studio productions root because it is the entry point for the Phase 1 DB-driven pipeline and uses a stable JSON API.

### Fixes Applied
- Added studio models:
  - `StudioProduction`
  - `StudioSceneSummary`
  - production count/list/create response wrappers
- Added API helpers:
  - `fetchStudioProductions()`
  - `createStudioProduction(...)`
  - `fetchStudioProduction(id:)`
  - `runStudioBreakdown(...)`
  - `fetchStudioScene(id:)`
- Added native `StudioView`:
  - AI Studio header and subtitle
  - productions list from `/api/backstage/studio/productions`
  - production cards with status/genre/language badges
  - Arabic title, synopsis, scene previews, scene counts, country/dialect metadata
  - loading, empty, and error states
  - create-production sheet with title, Arabic title, synopsis, genre, country, and dialect
- Added Profile `AI Studio` navigation row.
- Added native production detail:
  - fetches `/api/backstage/studio/productions/[id]`
  - production metadata header
  - scene count and country/dialect metadata
  - script breakdown panel with concept, cultural constraints, and episode length
  - calls `/api/backstage/studio/productions/[id]/breakdown`
  - reloads scenes after breakdown
  - scene list and empty state
- Added native scene detail:
  - fetches `/api/backstage/studio/scenes/[sceneId]`
  - scene metadata header
  - visual brief display
  - shot list with shot type/status/lip badges
  - shot action, duration, emotion, location, character IDs
  - Arabic and English dialogue blocks

### Design/Style Parity
- Studio productions root mirrors the mobile web structure: dark backstage surface, purple studio accent, compact badges, production cards, scene previews, and modal-style create form.
- Country/dialect cascading is implemented for the initial native set matching the web intent, though not every web `COUNTRY_DIALECTS` entry is represented yet.
- Production detail mirrors the web workflow shape: production metadata first, AI breakdown controls, and scene list generated from the backend.
- Scene detail mirrors the web storyboard/readout hierarchy: scene metadata, visual brief, shot cards, and dialogue blocks with Arabic RTL rendering.

### Known Gap
- Studio cast library, jobs, pipeline streaming NDJSON, status polling, cancellation, asset preview, visual-brief generation, stitch/review actions, and cost logs remain to be implemented.
- Backstage/Admin broader surfaces remain mostly web-only in native: network analytics, schedules/templates/regions, contracts, products, members, billing admin, platform admin, inspector, cleanup, and debugger.
- Studio APIs currently lack strict RBAC per docs known issue; native does not add client-side RBAC beyond authenticated access.

### Validation
- Live Xcode diagnostics clean for `StudioView`, `ProfileView`, `Models`, and `APIClient`.
- Full Xcode build passed after Studio root slice: `/var/folders/bt/mrgclqgx5wjgh1s_0rs3njrh0000gn/T/ActionArtifacts/840B781E-C1E9-4E19-A01D-BA5500D95EC5/BuildProject/BuildProject-Log-20260705-144117.txt`.
- Live Xcode diagnostics clean for `StudioView`, `Models`, and `APIClient`.
- Full Xcode build passed after Studio production-detail slice: `/var/folders/bt/mrgclqgx5wjgh1s_0rs3njrh0000gn/T/ActionArtifacts/840B781E-C1E9-4E19-A01D-BA5500D95EC5/BuildProject/BuildProject-Log-20260705-144411.txt`.
- Live Xcode diagnostics clean for `StudioView`, `Models`, and `APIClient`.
- Full Xcode build passed after Studio scene-detail slice: `/var/folders/bt/mrgclqgx5wjgh1s_0rs3njrh0000gn/T/ActionArtifacts/840B781E-C1E9-4E19-A01D-BA5500D95EC5/BuildProject/BuildProject-Log-20260705-144625.txt`.
