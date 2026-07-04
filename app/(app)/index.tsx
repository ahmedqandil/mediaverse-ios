/**
 * Home screen — full parity with web HomeFeedClient + ContinueWatching.
 *
 * Feed logic (mirrors HomeFeedClient.tsx exactly):
 *   • Fetch /api/feed-config → { mobileCarouselEvery, mobileCarouselCount, carouselSlots }
 *   • After every mobileCarouselEvery videos, insert the next carousel slot
 *   • Stop after mobileCarouselCount carousels; remaining appended after videos run out
 *   • Slot types: shows (2:3) | microdramas (9:16 purple) | channels | shorts (9:16) | videos
 *
 * VideoFeedCard:
 *   • Full-width 16:9 thumbnail with duration badge (bottom-right)
 *   • Auto-previews when ≥70% visible on screen via onViewableItemsChanged
 *   • "Tap to watch" pill shown while previewing (hides duration badge)
 *   • One video plays at a time — global coordination via playingVideoId state
 *
 * ContinueWatching:
 *   • Uses /api/progress (not /api/history)
 *   • Supports both video AND episode items
 *   • Remove (×) button with optimistic update + server DELETE
 *   • Green progress bar at bottom of thumbnail
 *   • S{n} E{n} badge for episode items
 */
import { useEffect, useState, useCallback, useRef } from 'react';
import {
  View, Text, Image, FlatList, TouchableOpacity, Pressable,
  ActivityIndicator, StyleSheet, RefreshControl,
  Dimensions, ScrollView, ViewToken, Animated,
} from 'react-native';
import { VideoView, useVideoPlayer } from 'expo-video';
import { useRouter } from 'expo-router';
import { Screen } from '@/components/ui/Screen';
import { apiGet, apiDelete } from '@/lib/api';
import { C } from '@/lib/constants';

const { width: SW } = Dimensions.get('window');
const THUMB_H = Math.round(SW * (9 / 16));   // full-width 16:9 thumbnail height
const HERO_H  = Math.round(SW * (9 / 16));   // hero banner same ratio

// ─── Types ────────────────────────────────────────────────────────────────────

interface FeedConfig {
  mobileCarouselEvery: number;
  mobileCarouselCount: number;
  carouselSlots: Array<{ id: string; type: string; label: string }>;
}

interface FeedVideo {
  id:           string;
  title:        string;
  thumbnailUrl: string | null;
  videoUrl:     string | null;
  duration:     number | null;
  views:        number;
  createdAt:    string;
  channel: { id: string; name: string; handle: string; avatarUrl: string | null } | null;
  show:    { id: string; title: string; coverUrl: string | null } | null;
}

interface Show {
  id: string; title: string;
  coverUrl: string | null; bannerUrl: string | null;
  genre: string | null; description: string | null;
  productionYear?: string | null;
  _count?: { seasons: number };
}

interface Channel {
  id: string; name: string; handle: string;
  avatarUrl: string | null; verified: boolean;
  _count: { followers: number; videos: number };
}

interface ShortVideo {
  id: string; title: string;
  thumbnailUrl: string | null; duration: number | null; views: number;
  channel: { id: string; name: string; handle: string } | null;
}

interface MicrodramaItem {
  id: string; title: string;
  genre: string | null; coverUrl: string | null;
}

interface ProgressItem {
  id: string; seconds: number; percent: number;
  videoId: string | null; episodeId: string | null;
  video: {
    id: string; title: string;
    thumbnailUrl: string | null; duration: number | null; type: string;
    channel: { id: string; name: string; handle: string } | null;
  } | null;
  episode: {
    id: string; title: string;
    thumbnailUrl: string | null; duration: number | null; episodeNumber: number;
    season: {
      seasonNumber: number;
      show: { id: string; title: string; coverUrl: string | null };
    };
  } | null;
}

// ─── Feed item union ──────────────────────────────────────────────────────────

type CarouselPool = {
  shows: Show[]; channels: Channel[]; shorts: ShortVideo[];
  microdramas: MicrodramaItem[]; videos: FeedVideo[];
};

type FeedItem =
  | { key: string; kind: 'hero';     show: Show | null;   fallback: FeedVideo | null }
  | { key: string; kind: 'continue'; items: ProgressItem[] }
  | { key: string; kind: 'foryou' }
  | { key: string; kind: 'video';    data: FeedVideo }
  | { key: string; kind: 'carousel'; label: string; slotType: string; pool: CarouselPool }
  | { key: string; kind: 'loader' }
  | { key: string; kind: 'end' };

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtDuration(secs: number | null): string {
  if (!secs) return '';
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${m}:${String(s).padStart(2, '0')}`;
}

function fmtViews(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M views`;
  if (n >= 1_000)     return `${(n / 1_000).toFixed(1)}K views`;
  return `${n} views`;
}

function fmtFollowers(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000)     return `${(n / 1_000).toFixed(1)}K`;
  return `${n}`;
}

// ─── Avatar ───────────────────────────────────────────────────────────────────

function Avatar({ uri, name, size = 36 }: { uri: string | null; name: string; size?: number }) {
  return (
    <View style={{
      width: size, height: size, borderRadius: size / 2,
      overflow: 'hidden', backgroundColor: 'rgba(255,255,255,0.08)',
      alignItems: 'center', justifyContent: 'center',
    }}>
      {uri
        ? <Image source={{ uri }} style={{ width: size, height: size }} resizeMode="cover" />
        : <Text style={{ fontSize: size * 0.38, fontWeight: '700', color: 'rgba(255,255,255,0.5)', textTransform: 'uppercase' }}>
            {name.charAt(0)}
          </Text>}
    </View>
  );
}

// ─── Hero banner ──────────────────────────────────────────────────────────────

function HeroBanner({ show, fallback, onWatch, onInfo }: {
  show: Show | null; fallback: FeedVideo | null;
  onWatch: () => void; onInfo: () => void;
}) {
  const owner = show ?? fallback;
  if (!owner) return null;
  const img   = show?.bannerUrl ?? show?.coverUrl ?? fallback?.thumbnailUrl;
  const badge = show ? 'Featured Series' : 'Just Added';

  return (
    <View style={hb.wrap}>
      {img
        ? <Image source={{ uri: img }} style={StyleSheet.absoluteFill} resizeMode="cover" />
        : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
      {/* Bottom gradient scrim */}
      <View style={hb.scrim} />
      <View style={hb.content}>
        <Text style={hb.badge}>{badge}</Text>
        <Text style={hb.title} numberOfLines={2}>{owner.title}</Text>
        {show?.genre ? <Text style={hb.meta}>{show.genre}</Text> : null}
        <View style={hb.btns}>
          <TouchableOpacity style={hb.btnWatch} onPress={onWatch} activeOpacity={0.85}>
            <Text style={hb.btnWatchTxt}>▶  Watch Now</Text>
          </TouchableOpacity>
          <TouchableOpacity style={hb.btnInfo} onPress={onInfo} activeOpacity={0.8}>
            <Text style={hb.btnInfoTxt}>ℹ  More Info</Text>
          </TouchableOpacity>
        </View>
      </View>
    </View>
  );
}

const hb = StyleSheet.create({
  wrap:       { width: SW, height: HERO_H, marginBottom: 4 },
  scrim:      { position: 'absolute', bottom: 0, left: 0, right: 0, height: HERO_H * 0.75,
                backgroundColor: 'rgba(10,10,15,0.72)' },
  content:    { position: 'absolute', bottom: 0, left: 0, right: 0, padding: 20, paddingBottom: 24 },
  badge:      { fontSize: 10, fontWeight: '700', color: C.watch, letterSpacing: 1.5,
                textTransform: 'uppercase', marginBottom: 6 },
  title:      { fontSize: 22, fontWeight: '800', color: C.text, lineHeight: 28, marginBottom: 4 },
  meta:       { fontSize: 12, color: 'rgba(255,255,255,0.5)', marginBottom: 14 },
  btns:       { flexDirection: 'row', gap: 10, marginTop: 4 },
  btnWatch:   { paddingHorizontal: 20, paddingVertical: 10, borderRadius: 100, backgroundColor: C.watch },
  btnWatchTxt:{ fontSize: 13, fontWeight: '700', color: '#0a0a12' },
  btnInfo:    { paddingHorizontal: 20, paddingVertical: 10, borderRadius: 100,
                backgroundColor: 'rgba(255,255,255,0.15)',
                borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)' },
  btnInfoTxt: { fontSize: 13, fontWeight: '600', color: C.text },
});

// ─── Video preview (expo-video) ───────────────────────────────────────────────
// Separate component so useVideoPlayer is always called at mount, never conditionally

function VideoPreview({ url, isPlaying }: { url: string; isPlaying: boolean }) {
  const player = useVideoPlayer(url, (p) => {
    p.loop     = true;
    p.muted    = true;
    p.volume   = 0;
  });

  useEffect(() => {
    if (isPlaying) {
      player.play();
    } else {
      player.pause();
    }
  }, [isPlaying, player]);

  return (
    <VideoView
      player={player}
      style={StyleSheet.absoluteFill}
      contentFit="cover"
      nativeControls={false}
      allowsFullscreen={false}
      allowsPictureInPicture={false}
    />
  );
}

// ─── VideoFeedCard ────────────────────────────────────────────────────────────
// Matches web VideoFeedCard: full-width 16:9 thumb, duration badge, avatar info row.
// When isPlaying=true: shows video preview + "Tap to watch" pill.

function VideoFeedCard({ video, isPlaying, onPress }: {
  video: FeedVideo; isPlaying: boolean; onPress: () => void;
}) {
  const ownerName   = video.channel?.name   ?? video.show?.title   ?? '';
  const ownerAvatar = video.channel?.avatarUrl ?? video.show?.coverUrl ?? null;
  const dur         = fmtDuration(video.duration);

  // Fade in/out the video preview layer
  const previewOpacity = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.timing(previewOpacity, {
      toValue:         isPlaying ? 1 : 0,
      duration:        250,
      useNativeDriver: true,
    }).start();
  }, [isPlaying, previewOpacity]);

  return (
    <View style={vfc.wrap}>
      {/* Thumbnail + preview */}
      <TouchableOpacity onPress={onPress} activeOpacity={0.9} style={vfc.thumb}>
        {/* Static thumbnail always underneath */}
        {video.thumbnailUrl
          ? <Image source={{ uri: video.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}

        {/* Video preview — only mounted when URL exists (hook still always called inside component) */}
        {video.videoUrl ? (
          <Animated.View style={[StyleSheet.absoluteFill, { opacity: previewOpacity }]}>
            <VideoPreview url={video.videoUrl} isPlaying={isPlaying} />
          </Animated.View>
        ) : null}

        {/* Play circle — visible when NOT previewing */}
        {!isPlaying && (
          <View style={vfc.playOverlay}>
            <View style={vfc.playCircle}>
              <Text style={vfc.playArrow}>▶</Text>
            </View>
          </View>
        )}

        {/* "Tap to watch" pill — visible while previewing */}
        {isPlaying && (
          <View style={vfc.tapPill}>
            <Text style={vfc.tapPillTxt}>🔇  Tap to watch</Text>
          </View>
        )}

        {/* Duration badge — hidden while previewing */}
        {dur && !isPlaying && (
          <View style={vfc.durBadge}>
            <Text style={vfc.durTxt}>{dur}</Text>
          </View>
        )}
      </TouchableOpacity>

      {/* Info row */}
      <View style={vfc.info}>
        <Avatar uri={ownerAvatar} name={ownerName} size={36} />
        <View style={vfc.meta}>
          <TouchableOpacity onPress={onPress} activeOpacity={0.8}>
            <Text style={vfc.title} numberOfLines={2}>{video.title}</Text>
          </TouchableOpacity>
          {ownerName ? <Text style={vfc.channel} numberOfLines={1}>{ownerName}</Text> : null}
          <Text style={vfc.views}>{fmtViews(video.views)}</Text>
        </View>
      </View>
    </View>
  );
}

const vfc = StyleSheet.create({
  wrap:       { paddingHorizontal: 16, marginBottom: 20 },
  thumb:      { width: '100%' as const, height: THUMB_H, borderRadius: 12,
                overflow: 'hidden', backgroundColor: C.surface2, marginBottom: 10 },
  playOverlay:{ position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
                alignItems: 'center', justifyContent: 'center',
                backgroundColor: 'rgba(0,0,0,0.12)' },
  playCircle: { width: 52, height: 52, borderRadius: 26, backgroundColor: C.watch,
                alignItems: 'center', justifyContent: 'center',
                shadowColor: C.watch, shadowOpacity: 0.5, shadowRadius: 12, elevation: 8 },
  playArrow:  { fontSize: 16, color: '#0a0a12', marginLeft: 3 },
  tapPill:    { position: 'absolute', bottom: 10, left: 10,
                backgroundColor: 'rgba(0,0,0,0.72)',
                borderRadius: 20, paddingHorizontal: 12, paddingVertical: 5,
                borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)' },
  tapPillTxt: { color: '#fff', fontSize: 11, fontWeight: '600' },
  durBadge:   { position: 'absolute', bottom: 8, right: 8,
                backgroundColor: 'rgba(0,0,0,0.78)', borderRadius: 4,
                paddingHorizontal: 5, paddingVertical: 2 },
  durTxt:     { color: '#fff', fontSize: 11, fontWeight: '600' },
  info:       { flexDirection: 'row', gap: 10 },
  meta:       { flex: 1 },
  title:      { fontSize: 13, fontWeight: '600', color: C.text, lineHeight: 18, marginBottom: 3 },
  channel:    { fontSize: 12, color: 'rgba(255,255,255,0.5)', marginBottom: 2 },
  views:      { fontSize: 11, color: 'rgba(255,255,255,0.35)' },
});

// ─── Continue Watching ────────────────────────────────────────────────────────
// Uses /api/progress, handles both video + episode items.
// Remove button with optimistic update + server DELETE.

function ContinueWatchingSection({ items: initialItems, onPress }: {
  items: ProgressItem[];
  onPress: (item: ProgressItem) => void;
}) {
  const [items, setItems] = useState<ProgressItem[]>(initialItems);

  useEffect(() => { setItems(initialItems); }, [initialItems]);

  const router = useRouter();

  function handleRemove(item: ProgressItem) {
    setItems(prev => prev.filter(i => i.id !== item.id));
    const param = item.videoId ? `videoId=${item.videoId}` : `episodeId=${item.episodeId}`;
    apiDelete(`/api/progress?${param}`).catch(() => {
      // Restore on failure
      setItems(prev => [item, ...prev]);
    });
  }

  if (items.length === 0) return null;

  return (
    <View style={cws.section}>
      {/* Header */}
      <View style={cws.header}>
        <Text style={cws.label}>Continue Watching</Text>
        <TouchableOpacity onPress={() => router.push('/(app)/history' as never)} activeOpacity={0.7}>
          <Text style={cws.seeAll}>History →</Text>
        </TouchableOpacity>
      </View>

      {/* Horizontal scroll */}
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={cws.row}>
        {items.map(item => (
          item.video
            ? <CWVideoCard key={item.id} item={item} onPress={() => onPress(item)} onRemove={() => handleRemove(item)} />
            : item.episode
            ? <CWEpisodeCard key={item.id} item={item} onPress={() => onPress(item)} onRemove={() => handleRemove(item)} />
            : null
        ))}
      </ScrollView>
    </View>
  );
}

function CWVideoCard({ item, onPress, onRemove }: { item: ProgressItem; onPress: () => void; onRemove: () => void }) {
  const v   = item.video!;
  const pct = Math.min(Math.max(item.percent, 0), 1);
  return (
    <TouchableOpacity style={cwc.card} onPress={onPress} activeOpacity={0.8}>
      <View style={cwc.thumb}>
        {v.thumbnailUrl
          ? <Image source={{ uri: v.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
        {/* Play overlay */}
        <View style={cwc.playOverlay}>
          <View style={cwc.playCircle}><Text style={cwc.playArrow}>▶</Text></View>
        </View>
        {/* Remove button */}
        <TouchableOpacity style={cwc.removeBtn} onPress={(e) => { e.stopPropagation?.(); onRemove(); }} hitSlop={{ top: 6, bottom: 6, left: 6, right: 6 }} activeOpacity={0.8}>
          <Text style={cwc.removeTxt}>✕</Text>
        </TouchableOpacity>
        {/* Progress bar */}
        <View style={cwc.barBg}>
          <View style={[cwc.barFill, { width: `${Math.round(pct * 100)}%` as `${number}%` }]} />
        </View>
      </View>
      <Text style={cwc.title} numberOfLines={2}>{v.title}</Text>
      {v.channel ? <Text style={cwc.sub} numberOfLines={1}>{v.channel.name}</Text> : null}
    </TouchableOpacity>
  );
}

function CWEpisodeCard({ item, onPress, onRemove }: { item: ProgressItem; onPress: () => void; onRemove: () => void }) {
  const ep   = item.episode!;
  const show = ep.season.show;
  const pct  = Math.min(Math.max(item.percent, 0), 1);
  const epLabel = `S${ep.season.seasonNumber} E${ep.episodeNumber}`;
  return (
    <TouchableOpacity style={cwc.card} onPress={onPress} activeOpacity={0.8}>
      <View style={cwc.thumb}>
        {ep.thumbnailUrl
          ? <Image source={{ uri: ep.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          : show.coverUrl
          ? <Image source={{ uri: show.coverUrl }} style={[StyleSheet.absoluteFill, { opacity: 0.6 }]} resizeMode="cover" />
          : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
        {/* Episode label badge */}
        <View style={cwc.epBadge}><Text style={cwc.epBadgeTxt}>{epLabel}</Text></View>
        {/* Play overlay */}
        <View style={cwc.playOverlay}>
          <View style={cwc.playCircle}><Text style={cwc.playArrow}>▶</Text></View>
        </View>
        {/* Remove button */}
        <TouchableOpacity style={cwc.removeBtn} onPress={(e) => { e.stopPropagation?.(); onRemove(); }} hitSlop={{ top: 6, bottom: 6, left: 6, right: 6 }} activeOpacity={0.8}>
          <Text style={cwc.removeTxt}>✕</Text>
        </TouchableOpacity>
        {/* Progress bar */}
        <View style={cwc.barBg}>
          <View style={[cwc.barFill, { width: `${Math.round(pct * 100)}%` as `${number}%` }]} />
        </View>
      </View>
      <Text style={cwc.title} numberOfLines={2}>{ep.title || show.title}</Text>
      <Text style={cwc.sub} numberOfLines={1}>{show.title}</Text>
    </TouchableOpacity>
  );
}

const cws = StyleSheet.create({
  section: { marginBottom: 8 },
  header:  { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
              paddingHorizontal: 16, marginBottom: 10 },
  label:   { fontSize: 16, fontWeight: '700', color: C.text },
  seeAll:  { fontSize: 12, color: 'rgba(255,255,255,0.4)' },
  row:     { paddingHorizontal: 16 },
});
const cwc = StyleSheet.create({
  card:        { width: 168, marginRight: 12 },
  thumb:       { width: 168, height: 95, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  playOverlay: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
                 alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.35)' },
  playCircle:  { width: 34, height: 34, borderRadius: 17, backgroundColor: C.watch,
                 alignItems: 'center', justifyContent: 'center' },
  playArrow:   { fontSize: 13, color: '#0a0a12', marginLeft: 2 },
  removeBtn:   { position: 'absolute', top: 6, right: 6,
                 width: 22, height: 22, borderRadius: 11,
                 backgroundColor: 'rgba(0,0,0,0.75)',
                 alignItems: 'center', justifyContent: 'center' },
  removeTxt:   { color: 'rgba(255,255,255,0.8)', fontSize: 9, fontWeight: '700' },
  epBadge:     { position: 'absolute', top: 6, left: 6,
                 backgroundColor: 'rgba(0,0,0,0.72)',
                 borderRadius: 4, paddingHorizontal: 5, paddingVertical: 2 },
  epBadgeTxt:  { color: 'rgba(255,255,255,0.85)', fontSize: 9, fontWeight: '700' },
  barBg:       { position: 'absolute', bottom: 0, left: 0, right: 0, height: 3, backgroundColor: 'rgba(255,255,255,0.2)' },
  barFill:     { height: 3, backgroundColor: C.watch },
  title:       { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
  sub:         { color: C.textMuted, fontSize: 10, marginTop: 2 },
});

// ─── Carousel card components ─────────────────────────────────────────────────

// Shows → 2:3 portrait card
function ShowCard({ show, onPress }: { show: Show; onPress: () => void }) {
  const img = show.coverUrl ?? show.bannerUrl;
  return (
    <Pressable style={sc.card} onPress={onPress}>
      {({ pressed }) => (
        <>
          <View style={[sc.thumb, pressed && { opacity: 0.85 }]}>
            {img
              ? <Image source={{ uri: img }} style={StyleSheet.absoluteFill} resizeMode="cover" />
              : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2, alignItems: 'center', justifyContent: 'center' }]}>
                  <Text style={{ fontSize: 26, color: 'rgba(255,255,255,0.15)' }}>📺</Text>
                </View>}
            {/* Play overlay */}
            <View style={[sc.playLayer, { opacity: pressed ? 1 : 0 }]}>
              <View style={sc.playCircle}><Text style={{ fontSize: 14, color: '#0a0a12', marginLeft: 2 }}>▶</Text></View>
            </View>
          </View>
          <Text style={sc.title} numberOfLines={2}>{show.title}</Text>
          {(show.genre || show._count?.seasons) ? (
            <Text style={sc.sub} numberOfLines={1}>
              {[show.productionYear, show._count?.seasons ? `${show._count.seasons} season${show._count.seasons !== 1 ? 's' : ''}` : null].filter(Boolean).join(' · ')}
              {!show.productionYear && !show._count?.seasons && show.genre}
            </Text>
          ) : null}
        </>
      )}
    </Pressable>
  );
}
const sc = StyleSheet.create({
  card:      { width: 110, marginRight: 12 },
  thumb:     { width: 110, height: 165, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  playLayer: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
               backgroundColor: 'rgba(0,0,0,0.3)', alignItems: 'center', justifyContent: 'center' },
  playCircle:{ width: 38, height: 38, borderRadius: 19, backgroundColor: C.watch,
               alignItems: 'center', justifyContent: 'center' },
  title:     { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
  sub:       { color: C.textMuted, fontSize: 10, marginTop: 2 },
});

// Microdramas → 9:16 with purple gradient overlay + badge
function MicrodramaCard({ show, onPress }: { show: MicrodramaItem; onPress: () => void }) {
  return (
    <Pressable style={mdc.card} onPress={onPress}>
      {({ pressed }) => (
        <>
          <View style={[mdc.thumb, pressed && { opacity: 0.85 }]}>
            {show.coverUrl
              ? <Image source={{ uri: show.coverUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
              : <View style={[StyleSheet.absoluteFill, { backgroundColor: '#1a0a2e', alignItems: 'center', justifyContent: 'center' }]}>
                  <Text style={{ fontSize: 28, color: 'rgba(255,255,255,0.15)' }}>📱</Text>
                </View>}
            {/* Gradient scrim */}
            <View style={mdc.scrim} />
            {/* MICRODRAMA badge */}
            <View style={mdc.badge}>
              <Text style={mdc.badgeTxt}>Microdrama</Text>
            </View>
            {/* Title + genre overlay */}
            <View style={mdc.footer}>
              <Text style={mdc.title} numberOfLines={2}>{show.title}</Text>
              {show.genre ? <Text style={mdc.genre} numberOfLines={1}>{show.genre}</Text> : null}
            </View>
          </View>
        </>
      )}
    </Pressable>
  );
}
const mdc = StyleSheet.create({
  card:     { width: 110, marginRight: 12 },
  thumb:    { width: 110, height: 196, borderRadius: 10, overflow: 'hidden', backgroundColor: '#1a0a2e' },
  scrim:    { position: 'absolute', bottom: 0, left: 0, right: 0, height: '60%',
              backgroundColor: 'rgba(10,0,20,0.75)' },
  badge:    { position: 'absolute', top: 7, left: 7,
              backgroundColor: 'rgba(124,106,247,0.85)',
              borderRadius: 20, paddingHorizontal: 7, paddingVertical: 3 },
  badgeTxt: { color: '#fff', fontSize: 8, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5 },
  footer:   { position: 'absolute', bottom: 0, left: 0, right: 0, padding: 8 },
  title:    { color: '#fff', fontSize: 11, fontWeight: '700', lineHeight: 14, marginBottom: 2 },
  genre:    { color: 'rgba(255,255,255,0.45)', fontSize: 9 },
});

// Shorts → 9:16 with SHORT badge
function ShortCard({ video, onPress }: { video: ShortVideo; onPress: () => void }) {
  const dur = fmtDuration(video.duration);
  return (
    <Pressable style={shc.card} onPress={onPress}>
      {({ pressed }) => (
        <>
          <View style={[shc.thumb, pressed && { opacity: 0.85 }]}>
            {video.thumbnailUrl
              ? <Image source={{ uri: video.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
              : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
            {/* SHORT badge */}
            <View style={shc.badge}><Text style={shc.badgeTxt}>Short</Text></View>
            {/* Play overlay */}
            <View style={[shc.playLayer, { opacity: pressed ? 1 : 0 }]}>
              <View style={shc.playCircle}><Text style={{ fontSize: 13, color: '#0a0a12', marginLeft: 2 }}>▶</Text></View>
            </View>
            {dur ? <View style={shc.dur}><Text style={shc.durTxt}>{dur}</Text></View> : null}
          </View>
          <Text style={shc.title} numberOfLines={2}>{video.title}</Text>
          {video.channel ? <Text style={shc.sub} numberOfLines={1}>{video.channel.name}</Text> : null}
        </>
      )}
    </Pressable>
  );
}
const shc = StyleSheet.create({
  card:      { width: 110, marginRight: 12 },
  thumb:     { width: 110, height: 196, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  badge:     { position: 'absolute', top: 7, left: 7, backgroundColor: 'rgba(0,0,0,0.72)',
               borderRadius: 4, paddingHorizontal: 6, paddingVertical: 3 },
  badgeTxt:  { color: 'rgba(255,255,255,0.85)', fontSize: 8, fontWeight: '700',
               textTransform: 'uppercase', letterSpacing: 0.5 },
  playLayer: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
               backgroundColor: 'rgba(0,0,0,0.3)', alignItems: 'center', justifyContent: 'center' },
  playCircle:{ width: 36, height: 36, borderRadius: 18, backgroundColor: C.watch, alignItems: 'center', justifyContent: 'center' },
  dur:       { position: 'absolute', bottom: 6, right: 6, backgroundColor: 'rgba(0,0,0,0.72)',
               borderRadius: 3, paddingHorizontal: 5, paddingVertical: 2 },
  durTxt:    { color: '#fff', fontSize: 10, fontWeight: '600' },
  title:     { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
  sub:       { color: C.textMuted, fontSize: 10, marginTop: 2 },
});

// Channel compact card — centered avatar + name + followers + follow button
function ChannelCompactCard({ channel, onPress }: { channel: Channel; onPress: () => void }) {
  const [following, setFollowing] = useState(false);
  return (
    <Pressable style={chc.card} onPress={onPress}>
      {/* Avatar with subtle ring */}
      <View style={chc.avatarWrap}>
        <Avatar uri={channel.avatarUrl} name={channel.name} size={56} />
      </View>
      <View style={chc.nameRow}>
        <Text style={chc.name} numberOfLines={1}>{channel.name}</Text>
        {channel.verified ? <Text style={chc.tick}> ✓</Text> : null}
      </View>
      <Text style={chc.followers}>{fmtFollowers(channel._count.followers)} followers</Text>
      {/* Follow toggle */}
      <TouchableOpacity
        style={[chc.followBtn, following && chc.followingBtn]}
        onPress={(e) => { e.stopPropagation?.(); setFollowing(f => !f); }}
        activeOpacity={0.8}
      >
        <Text style={[chc.followTxt, following && chc.followingTxt]}>
          {following ? 'Following' : 'Follow'}
        </Text>
      </TouchableOpacity>
    </Pressable>
  );
}
const chc = StyleSheet.create({
  card:        { width: 100, alignItems: 'center', marginRight: 14 },
  avatarWrap:  { width: 62, height: 62, borderRadius: 31, padding: 3,
                 borderWidth: 1, borderColor: 'rgba(255,255,255,0.1)',
                 alignItems: 'center', justifyContent: 'center', marginBottom: 6 },
  nameRow:     { flexDirection: 'row', alignItems: 'center', maxWidth: 96 },
  name:        { color: C.text, fontSize: 11, fontWeight: '700', textAlign: 'center' },
  tick:        { color: C.watch, fontSize: 10, fontWeight: '700' },
  followers:   { color: C.textMuted, fontSize: 9, marginTop: 2, marginBottom: 6 },
  followBtn:   { paddingHorizontal: 12, paddingVertical: 5, borderRadius: 100,
                 borderWidth: 1, borderColor: C.watch, backgroundColor: 'transparent' },
  followingBtn:{ backgroundColor: 'rgba(0,230,118,0.12)', borderColor: 'rgba(0,230,118,0.3)' },
  followTxt:   { color: C.watch, fontSize: 10, fontWeight: '700' },
  followingTxt:{ color: 'rgba(0,230,118,0.6)' },
});

// Videos carousel card → 16:9 landscape (same visual as VideoFeedCard but smaller)
function VideoCarouselCard({ video, onPress }: { video: FeedVideo; onPress: () => void }) {
  const dur = fmtDuration(video.duration);
  return (
    <Pressable style={vcc.card} onPress={onPress}>
      {({ pressed }) => (
        <>
          <View style={[vcc.thumb, pressed && { opacity: 0.85 }]}>
            {video.thumbnailUrl
              ? <Image source={{ uri: video.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
              : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
            {dur ? <View style={vcc.dur}><Text style={vcc.durTxt}>{dur}</Text></View> : null}
          </View>
          <Text style={vcc.title} numberOfLines={2}>{video.title}</Text>
          {video.channel ? <Text style={vcc.sub} numberOfLines={1}>{video.channel.name}</Text> : null}
        </>
      )}
    </Pressable>
  );
}
const vcc = StyleSheet.create({
  card:  { width: 180, marginRight: 12 },
  thumb: { width: 180, height: 101, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  dur:   { position: 'absolute', bottom: 6, right: 6, backgroundColor: 'rgba(0,0,0,0.78)',
           borderRadius: 3, paddingHorizontal: 5, paddingVertical: 2 },
  durTxt:{ color: '#fff', fontSize: 10, fontWeight: '600' },
  title: { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
  sub:   { color: C.textMuted, fontSize: 10, marginTop: 2 },
});

// ─── CarouselRow — full-bleed tinted section with header ─────────────────────

const SLOT_ROUTES: Record<string, string> = {
  shows:       '/(app)/shows',
  microdramas: '/(app)/microdramas',
  channels:    '/(app)/channels',
  shorts:      '/(app)/shorts',
  videos:      '/',
};

const SLOT_BG: Record<string, string> = {
  shows:       'rgba(255,255,255,0.022)',
  microdramas: 'rgba(124,106,247,0.07)',
  channels:    'rgba(255,255,255,0.022)',
  shorts:      'rgba(255,255,255,0.022)',
  videos:      'rgba(255,255,255,0.022)',
};

function CarouselRow({ label, slotType, pool, onNavigate }: {
  label: string; slotType: string; pool: CarouselPool;
  onNavigate: (route: string) => void;
}) {
  const router         = useRouter();
  const isMicrodrama   = slotType === 'microdramas';
  const accent         = isMicrodrama ? C.listen : C.watch;
  const bg             = SLOT_BG[slotType] ?? 'rgba(255,255,255,0.022)';
  const seeAllRoute    = SLOT_ROUTES[slotType] ?? '/';

  function renderCards() {
    switch (slotType) {
      case 'shows':
        return pool.shows.map(s => (
          <ShowCard key={s.id} show={s} onPress={() => router.push(`/(app)/show/${s.id}` as never)} />
        ));
      case 'microdramas':
        return pool.microdramas.map(m => (
          <MicrodramaCard key={m.id} show={m} onPress={() => router.push(`/(app)/microdrama/${m.id}` as never)} />
        ));
      case 'channels':
        return pool.channels.map(ch => (
          <ChannelCompactCard key={ch.id} channel={ch} onPress={() => router.push(`/(app)/channel/${ch.handle}` as never)} />
        ));
      case 'shorts':
        return pool.shorts.map(s => (
          <ShortCard key={s.id} video={s} onPress={() => router.push(`/(app)/watch/${s.id}` as never)} />
        ));
      case 'videos':
        return pool.videos.slice(0, 8).map(v => (
          <VideoCarouselCard key={v.id} video={v} onPress={() => router.push(`/(app)/watch/${v.id}` as never)} />
        ));
      default:
        return [];
    }
  }

  const cards = renderCards();
  if (!cards.length) return null;

  return (
    <View style={[cr.section, { backgroundColor: bg }]}>
      {/* Header */}
      <View style={cr.header}>
        <View style={cr.headerLeft}>
          {isMicrodrama && (
            <View style={[cr.microBadge, { borderColor: 'rgba(124,106,247,0.3)' }]}>
              <Text style={[cr.microBadgeTxt, { color: accent }]}>Microdrama</Text>
            </View>
          )}
          <Text style={cr.label}>{label}</Text>
        </View>
        <TouchableOpacity
          onPress={() => onNavigate(seeAllRoute)}
          activeOpacity={0.7}
          style={cr.seeAllBtn}
        >
          <Text style={[cr.seeAllTxt, { color: accent }]}>See all ›</Text>
        </TouchableOpacity>
      </View>

      {/* Cards scroll row */}
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={cr.row}
      >
        {cards}
      </ScrollView>
    </View>
  );
}

const cr = StyleSheet.create({
  section:      { paddingTop: 16, paddingBottom: 18, marginBottom: 8 },
  header:       { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
                  paddingHorizontal: 16, marginBottom: 12 },
  headerLeft:   { flexDirection: 'row', alignItems: 'center', gap: 8, flex: 1 },
  label:        { fontSize: 16, fontWeight: '700', color: C.text },
  microBadge:   { borderWidth: 1, borderRadius: 20, paddingHorizontal: 8, paddingVertical: 3,
                  backgroundColor: 'rgba(124,106,247,0.12)' },
  microBadgeTxt:{ fontSize: 9, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5 },
  seeAllBtn:    { paddingLeft: 8 },
  seeAllTxt:    { fontSize: 12, fontWeight: '600', opacity: 0.8 },
  row:          { paddingHorizontal: 16 },
});

// ─── "For You" header ─────────────────────────────────────────────────────────

function ForYouHeader() {
  return (
    <View style={fy.wrap}>
      <Text style={fy.title}>For You</Text>
      <Text style={fy.sub}>Recommended</Text>
    </View>
  );
}
const fy = StyleSheet.create({
  wrap:  { flexDirection: 'row', alignItems: 'center', gap: 8,
           paddingHorizontal: 16, paddingTop: 16, paddingBottom: 4, marginBottom: 8 },
  title: { fontSize: 20, fontWeight: '800', color: C.text, letterSpacing: -0.3 },
  sub:   { fontSize: 11, fontWeight: '600', color: 'rgba(255,255,255,0.3)', marginTop: 2 },
});

// ─── Feed builder (mirrors HomeFeedClient.tsx interleave logic exactly) ───────

const DEFAULT_CONFIG: FeedConfig = {
  mobileCarouselEvery: 3,
  mobileCarouselCount: 3,
  carouselSlots: [
    { id: 'slot_1', type: 'shows',    label: 'TV Shows & Series' },
    { id: 'slot_2', type: 'channels', label: 'Channels'          },
    { id: 'slot_3', type: 'shorts',   label: 'Shorts'            },
  ],
};

function buildFeed(
  videos:    FeedVideo[],
  progress:  ProgressItem[],
  pool:      CarouselPool,
  config:    FeedConfig,
  heroShow:  Show | null,
  hasMore:   boolean,
): FeedItem[] {
  const items: FeedItem[] = [];

  // Hero
  items.push({ key: '__hero', kind: 'hero', show: heroShow, fallback: videos[0] ?? null });

  // Continue Watching
  if (progress.length > 0) {
    items.push({ key: '__continue', kind: 'continue', items: progress });
  }

  // "For You" header before video feed
  items.push({ key: '__foryou', kind: 'foryou' });

  // Mirror HomeFeedClient interleave logic exactly
  const everyN  = config.mobileCarouselEvery;
  const slots   = config.carouselSlots.slice(0, config.mobileCarouselCount);
  let   slotIdx = 0;

  videos.forEach((video, i) => {
    items.push({ key: `v-${video.id}`, kind: 'video', data: video });

    const videoNumber = i + 1;
    if (videoNumber % everyN === 0 && slotIdx < slots.length) {
      const slot = slots[slotIdx]!;
      const hasData = hasSlotData(slot.type, pool);
      if (hasData) {
        items.push({
          key: `carousel-${slot.id}-${i}`,
          kind: 'carousel',
          label: slot.label,
          slotType: slot.type,
          pool,
        });
      }
      // Always advance — matches web (even if no data, slot is consumed)
      slotIdx++;
    }
  });

  // Remaining slots appended after feed ends (mirrors web)
  slots.slice(slotIdx).forEach((slot) => {
    if (hasSlotData(slot.type, pool)) {
      items.push({
        key: `carousel-tail-${slot.id}`,
        kind: 'carousel',
        label: slot.label,
        slotType: slot.type,
        pool,
      });
    }
  });

  items.push({ key: '__end', kind: hasMore ? 'loader' : 'end' });
  return items;
}

function hasSlotData(type: string, pool: CarouselPool): boolean {
  switch (type) {
    case 'shows':       return pool.shows.length > 0;
    case 'microdramas': return pool.microdramas.length > 0;
    case 'channels':    return pool.channels.length > 0;
    case 'shorts':      return pool.shorts.length > 0;
    case 'videos':      return pool.videos.length > 0;
    default:            return false;
  }
}

// ─── Main screen ──────────────────────────────────────────────────────────────

export default function HomeScreen() {
  const router = useRouter();

  const [feedConfig,   setFeedConfig]   = useState<FeedConfig>(DEFAULT_CONFIG);
  const [videos,       setVideos]       = useState<FeedVideo[]>([]);
  const [cursor,       setCursor]       = useState<string | null>(null);
  const [hasMore,      setHasMore]      = useState(true);
  const [loadingMore,  setLoadingMore]  = useState(false);
  const [pool,         setPool]         = useState<CarouselPool>({ shows: [], channels: [], shorts: [], microdramas: [], videos: [] });
  const [progress,     setProgress]     = useState<ProgressItem[]>([]);
  const [heroShow,     setHeroShow]     = useState<Show | null>(null);
  const [loading,      setLoading]      = useState(true);
  const [refreshing,   setRefreshing]   = useState(false);

  // Viewability tracking for video autoplay
  const [playingVideoId, setPlayingVideoId] = useState<string | null>(null);
  const loadingMoreRef = useRef(false);
  const viewabilityConfig = useRef({ itemVisiblePercentThreshold: 70 });

  const onViewableItemsChanged = useRef(({ viewableItems }: { viewableItems: ViewToken[] }) => {
    const firstVideo = viewableItems.find(
      (t) => t.isViewable && (t.item as FeedItem)?.kind === 'video',
    );
    const vid = firstVideo ? (firstVideo.item as Extract<FeedItem, { kind: 'video' }>).data : null;
    setPlayingVideoId(vid?.videoUrl ? vid.id : null);
  });

  // ── Initial parallel load ────────────────────────────────────────────────────
  const load = useCallback(async () => {
    try {
      const [cfgRes, feedRes, showsRes, channelsRes, shortsRes, progressRes, microdramasRes] =
        await Promise.allSettled([
          apiGet<FeedConfig>('/api/feed-config'),
          apiGet<{ videos: FeedVideo[]; nextCursor: string | null }>('/api/feed'),
          apiGet<{ shows: Show[] }>('/api/shows?take=12'),
          apiGet<Channel[]>('/api/channels'),
          apiGet<{ shorts: ShortVideo[] }>('/api/shorts?limit=10'),
          apiGet<ProgressItem[]>('/api/progress'),
          apiGet<MicrodramaItem[]>('/api/microdramas?limit=10'),
        ]);

      if (cfgRes.status  === 'fulfilled') setFeedConfig(cfgRes.value);

      let feedVideos: FeedVideo[] = [];
      if (feedRes.status === 'fulfilled') {
        feedVideos = feedRes.value.videos ?? [];
        setVideos(feedVideos);
        setCursor(feedRes.value.nextCursor);
        setHasMore(!!feedRes.value.nextCursor);
      }

      const shows = showsRes.status === 'fulfilled' ? (showsRes.value.shows ?? []) : [];
      setHeroShow(shows[0] ?? null);

      const microdramas = microdramasRes.status === 'fulfilled'
        ? (Array.isArray(microdramasRes.value) ? microdramasRes.value : [])
        : [];

      setPool({
        shows,
        channels:    channelsRes.status === 'fulfilled'    ? (channelsRes.value    ?? []) : [],
        shorts:      shortsRes.status   === 'fulfilled'    ? (shortsRes.value.shorts ?? []) : [],
        microdramas,
        videos:      feedVideos,
      });

      if (progressRes.status === 'fulfilled' && Array.isArray(progressRes.value)) {
        setProgress(progressRes.value);
      }
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  // ── Infinite scroll ──────────────────────────────────────────────────────────
  const loadMore = useCallback(async () => {
    if (loadingMoreRef.current || !hasMore || !cursor) return;
    loadingMoreRef.current = true;
    setLoadingMore(true);
    try {
      const res = await apiGet<{ videos: FeedVideo[]; nextCursor: string | null }>(
        `/api/feed?cursor=${encodeURIComponent(cursor)}`,
      );
      const newVids = res.videos ?? [];
      setVideos(prev => [...prev, ...newVids]);
      setPool(prev => ({ ...prev, videos: [...prev.videos, ...newVids] }));
      setCursor(res.nextCursor);
      setHasMore(!!res.nextCursor);
    } catch { /* silent */ } finally {
      loadingMoreRef.current = false;
      setLoadingMore(false);
    }
  }, [cursor, hasMore]);

  // ── Handle navigate for "See all →" links ────────────────────────────────────
  const handleCarouselNavigate = useCallback((route: string) => {
    router.push(route as never);
  }, [router]);

  // ── Build feed ───────────────────────────────────────────────────────────────
  const feedItems = buildFeed(videos, progress, pool, feedConfig, heroShow, hasMore || loadingMore);

  // ── Render each feed item ────────────────────────────────────────────────────
  const renderItem = useCallback(({ item }: { item: FeedItem }) => {
    switch (item.kind) {

      case 'hero':
        return (
          <HeroBanner
            show={item.show}
            fallback={item.fallback}
            onWatch={() => {
              if (item.show)     router.push(`/(app)/show/${item.show.id}` as never);
              else if (item.fallback) router.push(`/(app)/watch/${item.fallback.id}` as never);
            }}
            onInfo={() => {
              if (item.show)     router.push(`/(app)/show/${item.show.id}` as never);
              else if (item.fallback) router.push(`/(app)/watch/${item.fallback.id}` as never);
            }}
          />
        );

      case 'continue':
        return (
          <ContinueWatchingSection
            items={item.items}
            onPress={(pi) => {
              if (pi.video)   router.push(`/(app)/watch/${pi.video.id}` as never);
              else if (pi.episode) router.push(`/(app)/watch/episode/${pi.episode.id}` as never);
            }}
          />
        );

      case 'foryou':
        return <ForYouHeader />;

      case 'video':
        return (
          <VideoFeedCard
            video={item.data}
            isPlaying={playingVideoId === item.data.id}
            onPress={() => router.push(`/(app)/watch/${item.data.id}` as never)}
          />
        );

      case 'carousel':
        return (
          <CarouselRow
            label={item.label}
            slotType={item.slotType}
            pool={item.pool}
            onNavigate={handleCarouselNavigate}
          />
        );

      case 'loader':
        return <View style={tail.wrap}><ActivityIndicator color={C.watch} size="small" /></View>;

      case 'end':
        return videos.length > 0
          ? <View style={tail.wrap}><Text style={tail.txt}>You&apos;ve seen it all</Text></View>
          : null;

      default:
        return null;
    }
  }, [playingVideoId, router, handleCarouselNavigate, videos.length]);

  // ── Loading skeleton ─────────────────────────────────────────────────────────
  if (loading) {
    return (
      <Screen>
        <View style={load_.topBar}>
          <Text style={load_.wordmark}>WeStreem</Text>
        </View>
        <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
          <ActivityIndicator color={C.watch} size="large" />
        </View>
      </Screen>
    );
  }

  return (
    <Screen>
      <FlatList
        data={feedItems}
        keyExtractor={(item) => item.key}
        renderItem={renderItem}
        showsVerticalScrollIndicator={false}
        onEndReached={loadMore}
        onEndReachedThreshold={0.6}
        initialNumToRender={5}
        maxToRenderPerBatch={4}
        windowSize={9}
        // Viewability for autoplay — must use refs to remain stable
        onViewableItemsChanged={onViewableItemsChanged.current}
        viewabilityConfig={viewabilityConfig.current}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={() => { setRefreshing(true); void load(); }}
            tintColor={C.watch}
          />
        }
        ListHeaderComponent={
          <View style={topBar.wrap}>
            <Text style={topBar.wordmark}>WeStreem</Text>
            <TouchableOpacity
              hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
              onPress={() => router.push('/(app)/search' as never)}
            >
              <Text style={topBar.search}>🔍</Text>
            </TouchableOpacity>
          </View>
        }
        ListEmptyComponent={
          <View style={tail.empty}>
            <Text style={{ fontSize: 42, marginBottom: 16 }}>📺</Text>
            <Text style={{ color: C.text, fontSize: 16, fontWeight: '700', marginBottom: 6 }}>Nothing here yet.</Text>
            <Text style={{ color: C.textMuted, fontSize: 13, textAlign: 'center' }}>Check back soon for new content.</Text>
          </View>
        }
        contentContainerStyle={{ paddingBottom: 48 }}
      />
    </Screen>
  );
}

const topBar = StyleSheet.create({
  wrap:     { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
              paddingHorizontal: 16, paddingTop: 16, paddingBottom: 8 },
  wordmark: { fontSize: 22, fontWeight: '800', color: C.text, letterSpacing: -0.5 },
  search:   { fontSize: 20 },
});

const load_ = StyleSheet.create({
  topBar:   { paddingHorizontal: 16, paddingTop: 16, paddingBottom: 8 },
  wordmark: { fontSize: 22, fontWeight: '800', color: C.text, letterSpacing: -0.5 },
});

const tail = StyleSheet.create({
  wrap:  { alignItems: 'center', paddingVertical: 24 },
  txt:   { color: C.textMuted, fontSize: 12 },
  empty: { alignItems: 'center', paddingTop: 60, paddingHorizontal: 32 },
});
