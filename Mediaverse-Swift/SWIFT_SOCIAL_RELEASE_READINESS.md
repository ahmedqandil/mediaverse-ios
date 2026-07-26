# Westreem Swift Social Layer — Traceability and Release Readiness

## Release rule

The Swift client consumes the existing production contracts exactly as implemented by the web client. This phase makes no backend, database, migration, API-shape, authentication, playback, advertising, or curation-policy changes.

Authoritative references:

- Requirements: `IOS_PORTING_DIRECTIVE.md` and the project `docs/` directory.
- Behavior: the `mediaverse` web repository.
- Native implementation: `Social/`, shared native player/comment components, `AppRoute`, `MainTabView`, and native curation views.

## Requirement traceability

| Area | Required behavior | Native evidence | Contract/QA evidence | Status |
|---|---|---|---|---|
| Release entry | The Atmosphere is the default home and social features are usable on a clean install | `SocialFeatureConfiguration`, `MainTabView` | Default-on and explicit-kill-switch contract tests | Complete |
| Atmosphere | One three-tab surface: The Atmosphere, Discover, My Vibes | `AtmosphereView`, `AtmosphereViewModel` | Feed decoding tests; full iOS build | Complete |
| Atmosphere feed | Ripples from followed people/Vibes and regular videos from followed Shows/Channels; no episodes or Shorts | `AtmosphereFeedItem`, `LegacySocialAPIAdapter.atmosphere` | `testAtmosphereUsesFrozenBareArrayEndpointAndFiltersWebExcludedMedia`; decoding tests | Complete |
| Atmosphere curation | Before/after listings wrap all tabs; inline listings inject only into tab one; organic order is unchanged | `AtmosphereView`, `AtmosphereViewModel` | Frozen web comparison; full iOS build | Complete |
| Discover | Aggregate curated topics, Ripples, videos, Shorts, people, Vibes, Shows, and Channels; Shows/Channels remain separate | `BrowseView`, `NativeCurationTemplateViews` | Full iOS build | Complete |
| My Vibes | List Vibes the user owns or belongs to | `AtmosphereView`, `LegacySocialAPIAdapter.myVibes` | Exact cursor/limit contract test | Complete |
| Vibe detail | Public/private visibility, membership/follow state, capabilities, feed, management entry | `VibeDetailView`, social models/adapter | Restricted-page and capability-denial decoding tests | Complete |
| Vibe membership | Personal Atmos use follow; community Vibes use join/request/leave | `VibeDetailView`, `LegacySocialAPIAdapter` | Personal-follow/community-join contract test | Complete |
| Vibe invitations | Capability-gated create/list/revoke UI; role restrictions; shareable links; opaque-token acceptance; notification deep links | `VibeInvitationsView`, `VibeInviteAcceptView`, adapter, `AppRoute.vibeInvite` | Exact GET/POST/DELETE/accept contract test; route precedence test; full iOS build | Complete |
| Ripple composer | Text, mentions, links, Westreem media, photos, polls, spoiler/comments settings, personal/Vibe destination | `RippleComposer`, mention utilities, adapter | Composer/link/poll contract test | Complete |
| Photo upload | Multi-photo upload/drag-equivalent picker using existing Vibe R2 prepare/proxy contracts | `RippleComposer`, adapter | R2 preparation/proxy contract test | Complete |
| Link/media preview | Resolve pasted links and preserve internal media attachment identity | `RippleComposer`, attachment models | Composer resolution contract test | Complete |
| Ripple display | Text, backgrounds, attachments, polls, mentions, metadata, counts, owner menu | `RippleCard` | Unknown attachment forward-compatibility test; full build | Complete |
| Polls | Vote, dismiss composer poll, result bars and counts | `RippleCard`, `RippleComposer`, adapter | Poll defaults and vote envelope tests | Complete |
| Energy | Add Energy replaces content likes; labels/meter/counts; comments retain likes | `RippleEngagementController`, `RippleCard`, shared watch/Short/Flash integrations | Ripple Energy is contract-tested; watch/episode/Short/Flash parity remains | In progress |
| Photo engagement | Per-image Energy and comments; Echo/share operate on the Ripple | `RippleCard`, `CommentThreadView`, adapter | Photo engagement and target-specific comment contract tests | Complete |
| Comments | Inline comments, replies, mentions, comment likes, owner edit/delete, shared native behavior | `CommentThreadView`, mention utilities | Management/reply contracts pass; Ripple cards still present comments as a sheet | In progress |
| Echo | Echo or quote-Echo Ripples and supported media to one or multiple destinations | `EchoVibeSheet`, `RippleComposer`, adapter | Ripple multi-destination contract passes; direct video/Short/clip/collection entry points remain | In progress |
| Playback | Native chromeless preview/handoff, one autoplay owner, native watch/Short routes, ads retained | `RippleCard`, `AtmosphereView`, existing player managers | Attached Ripple videos are not yet native autoplay previews | In progress |
| Clips | Video and episode clips open native playback at mark-in and stop at mark-out | `RippleClipAttachmentView`, `VideoWatchView`, `EpisodeWatchView` | Full iOS build | Complete |
| Flashes | Existing Flash tray/creation plus Energy integration | story views, `SocialFeatureConfiguration.flashesEnergyEnabled` | Feature flag exists but is not wired to Flash Energy UI | In progress |
| Personal Atmo | Channel-style profile, own Ripple composer, Atmo/Vibes/Mentions/Echoed/About, follow, pin/unpin | `AtmoProfileView` and social destination views | Self composer/tabs/pin pass build; other-user header/About/Vibes/follow are API-blocked | Partial / frozen API |
| Affiliations | Vibe requests Show/Channel affiliation; reviewer accepts/rejects; notifications/deep links | `VibeAffiliationsView`, adapter, notifications | Requester/reviewer exact-contract tests | Complete within frozen API |
| Moderation | Ripple review/action, reports, member roles/suspension/ban/removal, join review | Vibe moderation views, adapter | Moderation/member exact-contract tests | Complete within frozen API |
| Notifications | Decode and route new social events to native Vibe/Ripple/Atmo destinations | notification models, `PushNotificationManager`, `NotificationsView`, `AppRoute` | Core list/mark-all is aligned; native Flash/manage-tab routing and preferences remain | In progress |
| Curation entities | show, season, episode, video, short, channel, Ripple, person, Vibe, topic | `ContentItem.appRoute`, native curation cards | Season context is discarded and `stories` renders empty in the generic renderer | In progress |
| Curation attribution | Fire-and-forget mobile impression and click events without invalidating feed caches | `APIClient.trackCurationEvent`, `CurationEventTracker` | Full iOS build; frozen event contract audit | Complete |
| Safety | No backend changes; existing native auth/feed/player/ads remain owners | adapter-only integration and native handoffs | Backend worktree check; Swift dirty-file isolation; full build | Complete |

## Frozen-backend exceptions

These are server limitations, not omitted Swift implementations. The no-backend-change rule prohibits inventing unsupported behavior:

1. Individual Flashes are not a curation entity. Swift can render the existing Flash tray when the `stories` template is selected, but cannot rank individual Flashes through curation.
2. Topic curation has a `/discover?topic=` link but the public social discover endpoint has no topic filter. Native opens a prefilled search rather than fabricating a filtered feed.
3. `channels` is referenced by seed/client curation but is absent from canonical page keys on a clean backend.
4. Photo comments have no report/moderation contract.
5. The member-list endpoint returns active members only; suspended/banned members cannot be rediscovered for an unban workflow.
6. Removed Ripples cannot be restored reliably because the existing restore contract conflicts with the backend deletion state.
7. Direct DELETE bypasses moderation history/notifications; native moderation uses the moderation endpoint.
8. Resolving a report does not act on its target; the moderator performs the target action separately.
9. Membership/report-resolution notification types are not emitted by the current backend.
10. Show-affiliation notification context filtering and a public affiliated-Vibe query have existing backend limitations.

## QA evidence

- Swift contract suite: 38 tests, zero failures.
- Xcode test build:

```text
xcodebuild -project Mediaverse-Swift/Mediaverse.xcodeproj \
  -scheme Mediaverse \
  -destination 'platform=iOS Simulator,id=31A479A4-7E95-44FE-A4A8-38C62F022E30' \
  build-for-testing CODE_SIGNING_ALLOWED=NO
```

- Result: `TEST BUILD SUCCEEDED`.
- Unsigned optimized Release archive: `ARCHIVE SUCCEEDED`.
- Simulator cold launch reached the native sign-in surface without an app crash.
- Backend repository: no Swift-phase changes.
- Unrelated pre-existing player/ad work and credential-file deletions were deliberately excluded from social commits.

## Release checklist

- [x] Social features default on for clean installs.
- [ ] Every required feature retains and applies an explicit local kill switch.
- [ ] Every required frozen API path and envelope is contract-tested.
- [x] Unknown attachment kinds fail soft.
- [x] Private/restricted content fails closed.
- [x] Native playback and ad ownership are preserved.
- [x] Curation does not filter or reorder organic Atmosphere content.
- [x] Backend worktree remains untouched.
- [x] Contract suite passes.
- [x] Full iOS test build passes.
- [ ] Full iOS test suite passes after the latest social changes.
- [x] Unsigned optimized Release archive passes.
- [x] Cold-launch smoke test reaches authentication without crashing.
- [ ] Signed-in simulator smoke test against a reachable environment.
- [ ] Archive/signing validation with the production Apple team.
- [ ] Push branch and open/merge the release change through the project’s normal review process.
