# Swift social UI parity

Mobile web at `https://www.westreem.com` is the reference for social
terminology, content hierarchy, supported card types, action order, and
interaction behavior. Native Swift keeps platform-appropriate sheets,
navigation, media playback, and share controllers while preserving those
product contracts.

## QA reference

- Reference viewport: 430 × 932 points (iPhone 16 Pro Max class).
- Reference surfaces inspected live: The Atmosphere, Discover, Vibe
  management, Ripple Energy, inline comments, and Echo destination selection.
- Native physical-device smoke test: authenticated production account on an
  iPhone 16 Pro Max.
- Backend policy: no server or schema changes.

## Parity matrix

| Surface | Mobile-web contract | Native verification |
| --- | --- | --- |
| Primary navigation | Atmosphere/Home, Videos, Shorts, Discover, My Pulse | Present in native tab shell |
| Flashes tray | User and followed publisher Flashes above Atmosphere | Present in native Atmosphere |
| Atmosphere tabs | The Atmosphere, Discover, My Vibes | Present and production-decoded |
| Ripple composer | Text, mentions, photos, link recognition, poll, spoiler, close comments | Present in shared native composer |
| Text Ripple | Larger text without a media container | Present |
| Photo Ripple | 1–4+ grid, full viewer, per-photo Energy and comments | Present |
| Video Ripple | Chromeless feed preview, autoplay eligibility, watch handoff | Present |
| Clipping Ripple | Clip identity, range visualization, source playback handoff | Present |
| Link Ripple | Compact full-width image/title/description/domain card | Present |
| Collection Ripple | Native collection attachment and destination | Present |
| Echoed Ripple | Echo attribution, nested source preview, original destination | Present |
| Poll | Question, selection state, result bars, percentages, vote count | Present |
| Ripple identity | Author, handle, destination Vibe, timestamp context | Present |
| Ripple menu | Pin where supported, edit/delete for owner, report otherwise | Present |
| Action order | Add Energy, Comment, Echo, Share; zero counts hidden | Present |
| Inline comments | Inline expansion with composer, replies, editing, deletion, comment likes | Present through shared comments module |
| Echo | Content preview, personal Atmo, searched/multiple Vibe destinations, optional quote | Present |
| Energy input | Branded gradient meter, slider, Low/Electric anchors, 1–5 shortcuts, six SVG-tag choices | Shared across Ripples, photos, video/episode content, and Flashes |
| Energy display | Average/count only when Energy exists, top three SVG-tag keywords | Present |
| Personal Atmo | Channel-style identity, Atmo/Echoed/Mentions/About, own composer and pinning | Present |
| Community Vibe | Identity header, membership/follow state, composer capability, Ripple feed | Present |
| Vibe management | Settings, moderation, members, invitations, affiliations | Present |
| Discover hub | Separate Shows, Movies, Microdramas, Channels, People, Vibes, Collections plus curated listings | Present through native curation templates |
| Notifications | Social destinations route to the matching native entity | Covered by route contracts |
| Loading/failure/empty | Loading, retryable failure, legitimate empty state are distinct | Present |

## Live evidence

- `/api/subscriptions/feed`: authenticated response decoded to 28 native items.
- `/api/fan-clubs/discover?mode=FOR_YOU&limit=20`: decoded to 16 Ripples.
- `/api/fan-clubs?mine=1&limit=24`: decoded to 3 Vibes.
- Social contract suite: 40 passing tests.
- Full iOS XCTest suite: 99 passing tests.

