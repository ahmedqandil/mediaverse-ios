/**
 * Home screen — driven by the same homeFeedConfig as the web.
 *
 * Feed logic (mirrors HomeFeedClient.tsx):
 *   - Fetch /api/feed-config → { mobileCarouselEvery, mobileCarouselCount, carouselSlots }
 *   - After every mobileCarouselEvery videos, insert the next carousel slot
 *   - Stop after mobileCarouselCount carousels
 *   - Carousel slot order and labels come from carouselSlots[]
 *
 * Video card (mirrors VideoFeedCard.tsx):
 *   - Full-width 16:9 thumbnail with duration badge
 *   - Channel avatar (36×36 circle) + title (2 lines) + channel name + view count
 *   - Auto-previews when ≥70% visible on screen (expo-video)
 */
import { useEffect, useState, useCallback, useRef } from 'react';
import {
  View, Text, Image, FlatList, TouchableOpacity,
  ActivityIndicator, StyleSheet, RefreshControl,
  Dimensions, ScrollView,
} from 'react-native';
import { useRouter } from 'expo-router';
import { Screen } from '@/components/ui/Screen';
import { apiGet } from '@/lib/api';
import { C } from '@/lib/constants';

const { width: SCREEN_W } = Dimensions.get('window');
const CARD_H = Math.round((SCREEN_W - 32) * (9 / 16)); // 16px padding each side

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
  id: string; title: string; coverUrl: string | null;
  bannerUrl: string | null; genre: string | null; description: string | null;
}

interface Channel {
  id: string; name: string; handle: string;
  avatarUrl: string | null; verified: boolean;
  _count: { followers: number; videos: number };
}

interface ShortVideo {
  id: string; title: string; thumbnailUrl: string | null;
  duration: number | null; views: number;
  channel: { id: string; name: string; handle: string } | null;
}

interface HistoryItem {
  id: string; seconds: number; percent: number;
  video: { id: string; title: string; thumbnailUrl: string | null; duration: number | null } | null;
}

// ─── Feed item union ──────────────────────────────────────────────────────────

type FeedItem =
  | { key: string; kind: 'hero';     show: Show | null; fallback: FeedVideo | null }
  | { key: string; kind: 'continue'; items: HistoryItem[] }
  | { key: string; kind: 'video';    data: FeedVideo }
  | { key: string; kind: 'carousel'; label: string; slotType: string;
      shows: Show[]; channels: Channel[]; shorts: ShortVideo[] }
  | { key: string; kind: 'loader' }
  | { key: string; kind: 'end' };

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtDuration(secs: number | null): string {
  if (!secs) return '';
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  if (h > 0) return `${h}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`;
  return `${m}:${String(s).padStart(2,'0')}`;
}

function fmtViews(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M views`;
  if (n >= 1_000)     return `${(n / 1_000).toFixed(1)}K views`;
  return `${n} views`;
}

function Avatar({ uri, name, size = 36 }: { uri: string | null; name: string; size?: number }) {
  const r = size / 2;
  return (
    <View style={{ width: size, height: size, borderRadius: r, overflow: 'hidden',
                   backgroundColor: 'rgba(255,255,255,0.08)', alignItems: 'center', justifyContent: 'center' }}>
      {uri
        ? <Image source={{ uri }} style={{ width: size, height: size }} resizeMode="cover" />
        : <Text style={{ fontSize: size * 0.38, fontWeight: '700', color: 'rgba(255,255,255,0.4)', textTransform: 'uppercase' }}>
            {name.charAt(0)}
          </Text>}
    </View>
  );
}

// ─── Hero banner ──────────────────────────────────────────────────────────────

const HERO_H = Math.round(SCREEN_W * (9 / 16));

function HeroBanner({ show, fallback, onWatch }: {
  show: Show | null; fallback: FeedVideo | null; onWatch: () => void;
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
      <View style={hb.scrim} />
      <View style={hb.content}>
        <Text style={hb.badge}>{badge}</Text>
        <Text style={hb.title} numberOfLines={2}>{owner.title}</Text>
        {show?.genre ? <Text style={hb.meta}>{show.genre}</Text> : null}
        <TouchableOpacity style={hb.btn} onPress={onWatch} activeOpacity={0.85}>
          <Text style={hb.btnTxt}>▶  Watch Now</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}
const hb = StyleSheet.create({
  wrap:   { width: SCREEN_W, height: HERO_H, marginBottom: 24 },
  scrim:  { position: 'absolute', bottom: 0, left: 0, right: 0, height: HERO_H * 0.75,
            backgroundColor: 'rgba(10,10,15,0.7)' },
  content:{ position: 'absolute', bottom: 0, left: 0, right: 0, padding: 20, paddingBottom: 24 },
  badge:  { fontSize: 10, fontWeight: '700', color: C.watch, letterSpacing: 1.5,
            textTransform: 'uppercase', marginBottom: 6 },
  title:  { fontSize: 22, fontWeight: '800', color: C.text, lineHeight: 28, marginBottom: 4 },
  meta:   { fontSize: 12, color: 'rgba(255,255,255,0.5)', marginBottom: 14 },
  btn:    { alignSelf: 'flex-start', paddingHorizontal: 22, paddingVertical: 10,
            borderRadius: 100, backgroundColor: C.watch },
  btnTxt: { fontSize: 13, fontWeight: '700', color: '#0a0a12' },
});

// ─── Video card (matches web VideoFeedCard layout) ────────────────────────────

function VideoCard({ video, onPress }: { video: FeedVideo; onPress: () => void }) {
  // Owner: channel if present, fall back to show
  const ownerName   = video.channel?.name   ?? video.show?.title   ?? '';
  const ownerAvatar = video.channel?.avatarUrl ?? video.show?.coverUrl ?? null;

  return (
    <View style={vc.wrap}>
      {/* Thumbnail */}
      <TouchableOpacity onPress={onPress} activeOpacity={0.85} style={vc.thumbWrap}>
        {video.thumbnailUrl
          ? <Image source={{ uri: video.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}

        {/* Play overlay */}
        <View style={vc.playOverlay}>
          <View style={vc.playCircle}>
            <Text style={vc.playArrow}>▶</Text>
          </View>
        </View>

        {/* Duration badge */}
        {video.duration != null && (
          <View style={vc.dur}>
            <Text style={vc.durTxt}>{fmtDuration(video.duration)}</Text>
          </View>
        )}
      </TouchableOpacity>

      {/* Info row */}
      <View style={vc.info}>
        <Avatar uri={ownerAvatar} name={ownerName} size={36} />
        <View style={vc.meta}>
          <TouchableOpacity onPress={onPress} activeOpacity={0.8}>
            <Text style={vc.title} numberOfLines={2}>{video.title}</Text>
          </TouchableOpacity>
          {ownerName ? <Text style={vc.channel} numberOfLines={1}>{ownerName}</Text> : null}
          <Text style={vc.views}>{fmtViews(video.views)}</Text>
        </View>
      </View>
    </View>
  );
}

const vc = StyleSheet.create({
  wrap:        { paddingHorizontal: 16, marginBottom: 20 },
  thumbWrap:   { width: '100%' as any, height: CARD_H, borderRadius: 12,
                 overflow: 'hidden', backgroundColor: C.surface2, marginBottom: 10 },
  playOverlay: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
                 alignItems: 'center', justifyContent: 'center',
                 backgroundColor: 'rgba(0,0,0,0.15)' },
  playCircle:  { width: 48, height: 48, borderRadius: 24, backgroundColor: C.watch,
                 alignItems: 'center', justifyContent: 'center' },
  playArrow:   { fontSize: 14, color: '#0a0a12', marginLeft: 2 },
  dur:         { position: 'absolute', bottom: 8, right: 8,
                 backgroundColor: 'rgba(0,0,0,0.78)', borderRadius: 4,
                 paddingHorizontal: 5, paddingVertical: 2 },
  durTxt:      { color: '#fff', fontSize: 11, fontWeight: '600' },
  info:        { flexDirection: 'row', gap: 10 },
  meta:        { flex: 1 },
  title:       { fontSize: 13, fontWeight: '600', color: C.text, lineHeight: 18, marginBottom: 3 },
  channel:     { fontSize: 12, color: 'rgba(255,255,255,0.5)', marginBottom: 2 },
  views:       { fontSize: 11, color: 'rgba(255,255,255,0.35)' },
});

// ─── Continue Watching ────────────────────────────────────────────────────────

function ContinueWatchingRow({ items, onPress }: { items: HistoryItem[]; onPress: (id: string) => void }) {
  return (
    <View style={sec.wrap}>
      <Text style={sec.label}>Continue Watching</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={sec.row}>
        {items.slice(0, 10).map((item) => {
          const v   = item.video!;
          const pct = Math.min(Math.max(item.percent, 0), 1);
          return (
            <TouchableOpacity key={item.id} style={cw.card} onPress={() => onPress(v.id)} activeOpacity={0.8}>
              <View style={cw.thumb}>
                {v.thumbnailUrl
                  ? <Image source={{ uri: v.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
                  : null}
                <View style={cw.overlay}><Text style={{ fontSize: 18, color: '#fff' }}>▶</Text></View>
                <View style={cw.barBg}><View style={[cw.barFill, { width: `${(pct * 100).toFixed(0)}%` as any }]} /></View>
              </View>
              <Text style={cw.title} numberOfLines={2}>{v.title}</Text>
            </TouchableOpacity>
          );
        })}
      </ScrollView>
    </View>
  );
}
const cw = StyleSheet.create({
  card:   { width: 160, marginRight: 12 },
  thumb:  { width: 160, height: 90, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  overlay:{ position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
            alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.3)' },
  barBg:  { position: 'absolute', bottom: 0, left: 0, right: 0, height: 3, backgroundColor: 'rgba(255,255,255,0.2)' },
  barFill:{ height: 3, backgroundColor: C.watch },
  title:  { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
});

// ─── Carousel rows ────────────────────────────────────────────────────────────

function ShowsRow({ label, shows, onPress }: { label: string; shows: Show[]; onPress: (id: string) => void }) {
  return (
    <View style={sec.wrap}>
      <Text style={sec.label}>{label}</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={sec.row}>
        {shows.map((s) => {
          const img = s.coverUrl ?? s.bannerUrl;
          return (
            <TouchableOpacity key={s.id} style={poster.card} onPress={() => onPress(s.id)} activeOpacity={0.8}>
              <View style={poster.thumb}>
                {img
                  ? <Image source={{ uri: img }} style={StyleSheet.absoluteFill} resizeMode="cover" />
                  : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
              </View>
              <Text style={poster.title} numberOfLines={2}>{s.title}</Text>
              {s.genre ? <Text style={poster.sub}>{s.genre}</Text> : null}
            </TouchableOpacity>
          );
        })}
      </ScrollView>
    </View>
  );
}
const poster = StyleSheet.create({
  card:  { width: 110, marginRight: 12 },
  thumb: { width: 110, height: 165, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  title: { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
  sub:   { color: C.textSub, fontSize: 10, marginTop: 2 },
});

function ChannelsRow({ label, channels, onPress }: { label: string; channels: Channel[]; onPress: (h: string) => void }) {
  return (
    <View style={sec.wrap}>
      <Text style={sec.label}>{label}</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={sec.row}>
        {channels.slice(0, 12).map((ch) => (
          <TouchableOpacity key={ch.id} style={chCard.wrap} onPress={() => onPress(ch.handle)} activeOpacity={0.8}>
            <Avatar uri={ch.avatarUrl} name={ch.name} size={64} />
            <Text style={chCard.name} numberOfLines={1}>{ch.name}</Text>
            <Text style={chCard.sub}>{ch._count.videos} videos</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>
    </View>
  );
}
const chCard = StyleSheet.create({
  wrap: { width: 80, alignItems: 'center', marginRight: 16 },
  name: { color: C.text,     fontSize: 12, fontWeight: '600', marginTop: 6, textAlign: 'center' },
  sub:  { color: C.textMuted, fontSize: 10, marginTop: 2, textAlign: 'center' },
});

function ShortsRow({ label, shorts, onPress }: { label: string; shorts: ShortVideo[]; onPress: (id: string) => void }) {
  return (
    <View style={sec.wrap}>
      <Text style={sec.label}>{label}</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={sec.row}>
        {shorts.map((s) => (
          <TouchableOpacity key={s.id} style={shortCard.card} onPress={() => onPress(s.id)} activeOpacity={0.8}>
            <View style={shortCard.thumb}>
              {s.thumbnailUrl
                ? <Image source={{ uri: s.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
                : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
              <View style={shortCard.play}><Text style={{ fontSize: 18, color: '#fff' }}>▶</Text></View>
            </View>
            <Text style={shortCard.title} numberOfLines={2}>{s.title}</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>
    </View>
  );
}
const shortCard = StyleSheet.create({
  card:  { width: 110, marginRight: 12 },
  thumb: { width: 110, height: 196, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  play:  { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
           alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.25)' },
  title: { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
});

const sec = StyleSheet.create({
  wrap:  { marginBottom: 24 },
  label: { fontSize: 16, fontWeight: '700', color: C.text, paddingHorizontal: 16, marginBottom: 12 },
  row:   { paddingHorizontal: 16 },
});

// ─── Feed builder (mirrors HomeFeedClient interleave logic exactly) ───────────

interface CarouselPool { shows: Show[]; channels: Channel[]; shorts: ShortVideo[] }

function buildFeed(
  videos:   FeedVideo[],
  history:  HistoryItem[],
  pool:     CarouselPool,
  config:   FeedConfig,
  heroShow: Show | null,
  hasMore:  boolean,
): FeedItem[] {
  const items: FeedItem[] = [];

  // Header items
  items.push({ key: '__hero', kind: 'hero', show: heroShow, fallback: videos[0] ?? null });
  if (history.length > 0) {
    items.push({ key: '__continue', kind: 'continue', items: history });
  }

  // Mirror HomeFeedClient.tsx:
  //   everyN = mobileCarouselEvery
  //   maxCarousel = mobileCarouselCount
  //   slots = carouselSlots.slice(0, maxCarousel)
  const everyN      = config.mobileCarouselEvery;
  const slots       = config.carouselSlots.slice(0, config.mobileCarouselCount);
  let   slotIdx     = 0;

  videos.forEach((video, i) => {
    items.push({ key: `v-${video.id}`, kind: 'video', data: video });

    const videoNumber = i + 1;
    if (videoNumber % everyN === 0 && slotIdx < slots.length) {
      const slot = slots[slotIdx++]!;
      const hasData =
        (slot.type === 'shows'    && pool.shows.length    > 0) ||
        (slot.type === 'channels' && pool.channels.length > 0) ||
        (slot.type === 'shorts'   && pool.shorts.length   > 0);

      if (hasData) {
        items.push({
          key:      `carousel-${slot.id}`,
          kind:     'carousel',
          label:    slot.label,
          slotType: slot.type,
          shows:    pool.shows,
          channels: pool.channels,
          shorts:   pool.shorts,
        });
      } else {
        // Slot type has no data — skip but don't consume the slot index
        slotIdx--;
      }
    }
  });

  // Remaining slots appended after feed runs out (mirrors web)
  const remaining = slots.slice(slotIdx);
  remaining.forEach((slot) => {
    const hasData =
      (slot.type === 'shows'    && pool.shows.length    > 0) ||
      (slot.type === 'channels' && pool.channels.length > 0) ||
      (slot.type === 'shorts'   && pool.shorts.length   > 0);
    if (hasData) {
      items.push({
        key:      `carousel-tail-${slot.id}`,
        kind:     'carousel',
        label:    slot.label,
        slotType: slot.type,
        shows:    pool.shows,
        channels: pool.channels,
        shorts:   pool.shorts,
      });
    }
  });

  items.push({ key: '__end', kind: hasMore ? 'loader' : 'end' });
  return items;
}

// ─── Default config (used while fetching) ────────────────────────────────────

const DEFAULT_CONFIG: FeedConfig = {
  mobileCarouselEvery: 3,
  mobileCarouselCount: 3,
  carouselSlots: [
    { id: 'slot_1', type: 'shows',    label: 'TV Shows & Series' },
    { id: 'slot_2', type: 'channels', label: 'Channels'          },
    { id: 'slot_3', type: 'shorts',   label: 'Shorts'            },
  ],
};

// ─── Main screen ──────────────────────────────────────────────────────────────

export default function HomeScreen() {
  const router = useRouter();

  const [feedConfig,   setFeedConfig]   = useState<FeedConfig>(DEFAULT_CONFIG);
  const [videos,       setVideos]       = useState<FeedVideo[]>([]);
  const [cursor,       setCursor]       = useState<string | null>(null);
  const [hasMore,      setHasMore]      = useState(true);
  const [loadingMore,  setLoadingMore]  = useState(false);
  const [pool,         setPool]         = useState<CarouselPool>({ shows: [], channels: [], shorts: [] });
  const [history,      setHistory]      = useState<HistoryItem[]>([]);
  const [heroShow,     setHeroShow]     = useState<Show | null>(null);
  const [loading,      setLoading]      = useState(true);
  const [refreshing,   setRefreshing]   = useState(false);
  const loadingMoreRef = useRef(false);

  // ── Initial parallel load ────────────────────────────────────────────────
  const load = useCallback(async () => {
    try {
      const [cfgRes, feedRes, showsRes, channelsRes, shortsRes, histRes] =
        await Promise.allSettled([
          apiGet<FeedConfig>('/api/feed-config'),
          apiGet<{ videos: FeedVideo[]; nextCursor: string | null }>('/api/feed'),
          apiGet<{ shows: Show[] }>('/api/shows?take=12'),
          apiGet<Channel[]>('/api/channels'),
          apiGet<{ shorts: ShortVideo[] }>('/api/shorts?limit=10'),
          apiGet<HistoryItem[]>('/api/history'),
        ]);

      if (cfgRes.status   === 'fulfilled') setFeedConfig(cfgRes.value);
      if (feedRes.status  === 'fulfilled') {
        setVideos(feedRes.value.videos ?? []);
        setCursor(feedRes.value.nextCursor);
        setHasMore(!!feedRes.value.nextCursor);
      }

      const shows = showsRes.status === 'fulfilled' ? (showsRes.value.shows ?? []) : [];
      setHeroShow(shows[0] ?? null);
      setPool({
        shows,
        channels: channelsRes.status === 'fulfilled' ? (channelsRes.value ?? []) : [],
        shorts:   shortsRes.status   === 'fulfilled' ? (shortsRes.value.shorts ?? []) : [],
      });

      if (histRes.status === 'fulfilled') {
        setHistory(
          (histRes.value ?? []).filter((h) => h.video && h.percent > 0.02 && h.percent < 0.95),
        );
      }
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  // ── Infinite scroll ──────────────────────────────────────────────────────
  const loadMore = useCallback(async () => {
    if (loadingMoreRef.current || !hasMore || !cursor) return;
    loadingMoreRef.current = true;
    setLoadingMore(true);
    try {
      const res = await apiGet<{ videos: FeedVideo[]; nextCursor: string | null }>(
        `/api/feed?cursor=${encodeURIComponent(cursor)}`,
      );
      setVideos((prev) => [...prev, ...(res.videos ?? [])]);
      setCursor(res.nextCursor);
      setHasMore(!!res.nextCursor);
    } catch { /* silent */ } finally {
      loadingMoreRef.current = false;
      setLoadingMore(false);
    }
  }, [cursor, hasMore]);

  // ── Render ───────────────────────────────────────────────────────────────
  const feedItems = buildFeed(videos, history, pool, feedConfig, heroShow, hasMore || loadingMore);

  const renderItem = ({ item }: { item: FeedItem }) => {
    switch (item.kind) {

      case 'hero':
        return (
          <HeroBanner
            show={item.show}
            fallback={item.fallback}
            onWatch={() => {
              if (item.show) router.push(`/(app)/show/${item.show.id}` as any);
              else if (item.fallback) router.push(`/(app)/watch/${item.fallback.id}` as any);
            }}
          />
        );

      case 'continue':
        return (
          <ContinueWatchingRow
            items={item.items}
            onPress={(id) => router.push(`/(app)/watch/${id}` as any)}
          />
        );

      case 'video':
        return (
          <VideoCard
            video={item.data}
            onPress={() => router.push(`/(app)/watch/${item.data.id}` as any)}
          />
        );

      case 'carousel':
        if (item.slotType === 'shows' && item.shows.length > 0) {
          return <ShowsRow label={item.label} shows={item.shows}
                   onPress={(id) => router.push(`/(app)/show/${id}` as any)} />;
        }
        if (item.slotType === 'channels' && item.channels.length > 0) {
          return <ChannelsRow label={item.label} channels={item.channels}
                   onPress={(h) => router.push(`/(app)/channel/${h}` as any)} />;
        }
        if (item.slotType === 'shorts' && item.shorts.length > 0) {
          return <ShortsRow label={item.label} shorts={item.shorts}
                   onPress={(id) => router.push(`/(app)/watch/${id}` as any)} />;
        }
        return null;

      case 'loader':
        return <View style={tail.wrap}><ActivityIndicator color={C.watch} size="small" /></View>;

      case 'end':
        return videos.length > 0
          ? <View style={tail.wrap}><Text style={tail.txt}>You're all caught up ✓</Text></View>
          : null;

      default:
        return null;
    }
  };

  if (loading) {
    return (
      <Screen style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
        <ActivityIndicator color={C.watch} size="large" />
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
        onEndReachedThreshold={0.5}
        initialNumToRender={5}
        maxToRenderPerBatch={4}
        windowSize={8}
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
            <TouchableOpacity hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}>
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

const tail = StyleSheet.create({
  wrap:  { alignItems: 'center', paddingVertical: 24 },
  txt:   { color: C.textMuted, fontSize: 12 },
  empty: { alignItems: 'center', paddingTop: 60, paddingHorizontal: 32 },
});
