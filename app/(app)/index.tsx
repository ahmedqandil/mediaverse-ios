/**
 * Home screen — mirrors WeStreem web homepage logic.
 *
 * Feed structure (matches web mobileCarouselEvery=3):
 *   Hero banner
 *   Continue Watching row  (if history exists)
 *   Video  Video  Video
 *   ── Shows carousel ──
 *   Video  Video  Video   ← rendered as individual rows in FlatList
 *   ── Channels carousel ──
 *   Video  Video  Video
 *   ── Shorts carousel ──
 *   ... (carousels don't repeat after all 3 slots used)
 *   Load-more spinner
 *
 * Personalization: the server-side /api/feed already applies feedScore()
 * (recency decay × warm/liked channel boosts), so we just call it.
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
const CAROUSEL_EVERY = 3; // insert a carousel after every N videos (web default)

// ─── API types ────────────────────────────────────────────────────────────────

interface FeedVideo {
  id:           string;
  title:        string;
  thumbnailUrl: string | null;
  duration:     number | null;
  views:        number;
  createdAt:    string;
  channel: { id: string; name: string; handle: string; avatarUrl: string | null } | null;
}

interface Show {
  id: string; title: string; coverUrl: string | null;
  bannerUrl: string | null; genre: string | null; description: string | null;
}

interface Channel {
  id: string; name: string; handle: string;
  avatarUrl: string | null; bannerUrl: string | null;
  description: string | null; verified: boolean;
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

// ─── Feed item union type ─────────────────────────────────────────────────────

type FeedItem =
  | { key: string; kind: 'hero';     show: Show | null; fallback: FeedVideo | null }
  | { key: string; kind: 'continue'; items: HistoryItem[] }
  | { key: string; kind: 'video';    data: FeedVideo }
  | { key: string; kind: 'carousel'; label: string; carouselKind: 'shows' | 'channels' | 'shorts';
      shows?: Show[]; channels?: Channel[]; shorts?: ShortVideo[] }
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

function fmtCount(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000)     return `${(n / 1_000).toFixed(1)}K`;
  return `${n}`;
}

// ─── Hero banner ──────────────────────────────────────────────────────────────

const HERO_H = Math.round(SCREEN_W * (9 / 16));

function HeroBanner({ show, fallback, onWatch }: {
  show: Show | null; fallback: FeedVideo | null; onWatch: () => void;
}) {
  const img   = show?.bannerUrl ?? show?.coverUrl ?? fallback?.thumbnailUrl ?? null;
  const title = show?.title ?? fallback?.title ?? '';
  const badge = show ? 'Featured Series' : 'Just Added';
  return (
    <View style={hb.wrap}>
      {img ? <Image source={{ uri: img }} style={StyleSheet.absoluteFill} resizeMode="cover" />
           : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
      <View style={hb.grad} />
      <View style={hb.content}>
        <Text style={hb.badge}>{badge}</Text>
        <Text style={hb.title} numberOfLines={2}>{title}</Text>
        {show?.genre ? <Text style={hb.meta}>{show.genre}</Text> : null}
        <TouchableOpacity style={hb.btn} onPress={onWatch} activeOpacity={0.85}>
          <Text style={hb.btnTxt}>▶  Watch Now</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}
const hb = StyleSheet.create({
  wrap:   { width: SCREEN_W, height: HERO_H, marginBottom: 20 },
  grad:   { position: 'absolute', bottom: 0, left: 0, right: 0, height: HERO_H, backgroundColor: 'rgba(10,10,15,0.55)' },
  content:{ position: 'absolute', bottom: 0, left: 0, right: 0, padding: 20, paddingBottom: 22 },
  badge:  { fontSize: 10, fontWeight: '700', color: C.watch, letterSpacing: 1.5, textTransform: 'uppercase', marginBottom: 6 },
  title:  { fontSize: 22, fontWeight: '800', color: C.text, lineHeight: 28, marginBottom: 4 },
  meta:   { fontSize: 12, color: 'rgba(255,255,255,0.5)', marginBottom: 12 },
  btn:    { alignSelf: 'flex-start', flexDirection: 'row', alignItems: 'center',
            paddingHorizontal: 22, paddingVertical: 10, borderRadius: 100, backgroundColor: C.watch },
  btnTxt: { fontSize: 13, fontWeight: '700', color: '#0a0a12' },
});

// ─── Continue Watching row ────────────────────────────────────────────────────

function ContinueWatchingRow({ items, onPress }: {
  items: HistoryItem[]; onPress: (id: string) => void;
}) {
  return (
    <View style={{ marginBottom: 24 }}>
      <Text style={sec.label}>Continue Watching</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={sec.row}>
        {items.slice(0, 10).map((item) => {
          const v = item.video!;
          const pct = Math.min(Math.max(item.percent, 0), 1);
          return (
            <TouchableOpacity key={item.id} style={cw.card} onPress={() => onPress(v.id)} activeOpacity={0.8}>
              <View style={cw.thumb}>
                {v.thumbnailUrl ? <Image source={{ uri: v.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" /> : null}
                <View style={cw.overlay}><Text style={{ fontSize: 18, color: '#fff' }}>▶</Text></View>
                <View style={cw.bar}><View style={[cw.fill, { width: `${(pct * 100).toFixed(0)}%` as any }]} /></View>
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
  card:    { width: 160, marginRight: 12 },
  thumb:   { width: 160, height: 90, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  overlay: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.3)' },
  bar:     { position: 'absolute', bottom: 0, left: 0, right: 0, height: 3, backgroundColor: 'rgba(255,255,255,0.2)' },
  fill:    { height: 3, backgroundColor: C.watch },
  title:   { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
});

// ─── Video card (landscape 16:9) ─────────────────────────────────────────────

function VideoRow({ video, onPress }: { video: FeedVideo; onPress: () => void }) {
  return (
    <TouchableOpacity style={vr.wrap} onPress={onPress} activeOpacity={0.8}>
      <View style={vr.thumb}>
        {video.thumbnailUrl
          ? <Image source={{ uri: video.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
        {video.duration != null && (
          <View style={vr.dur}><Text style={vr.durTxt}>{fmtDuration(video.duration)}</Text></View>
        )}
      </View>
      <View style={vr.meta}>
        <Text style={vr.title} numberOfLines={2}>{video.title}</Text>
        {video.channel && <Text style={vr.channel} numberOfLines={1}>{video.channel.name}</Text>}
        <Text style={vr.views}>{fmtCount(video.views)} views</Text>
      </View>
    </TouchableOpacity>
  );
}
const vr = StyleSheet.create({
  wrap:    { flexDirection: 'row', gap: 12, paddingHorizontal: 20, marginBottom: 16, alignItems: 'flex-start' },
  thumb:   { width: 140, height: 79, borderRadius: 8, overflow: 'hidden', backgroundColor: C.surface2, flexShrink: 0 },
  dur:     { position: 'absolute', bottom: 4, right: 5, backgroundColor: 'rgba(0,0,0,0.75)', borderRadius: 4, paddingHorizontal: 4, paddingVertical: 1 },
  durTxt:  { color: '#fff', fontSize: 10, fontWeight: '600' },
  meta:    { flex: 1, paddingTop: 2 },
  title:   { color: C.text, fontSize: 13, fontWeight: '600', lineHeight: 18, marginBottom: 4 },
  channel: { color: C.textSub, fontSize: 11, marginBottom: 2 },
  views:   { color: C.textMuted, fontSize: 11 },
});

// ─── Carousel section ─────────────────────────────────────────────────────────

function ShowsCarousel({ label, shows, onPress }: { label: string; shows: Show[]; onPress: (id: string) => void }) {
  return (
    <View style={car.wrap}>
      <Text style={sec.label}>{label}</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={sec.row}>
        {shows.map((s) => {
          const img = s.coverUrl ?? s.bannerUrl;
          return (
            <TouchableOpacity key={s.id} style={car.poster} onPress={() => onPress(s.id)} activeOpacity={0.8}>
              <View style={car.posterThumb}>
                {img ? <Image source={{ uri: img }} style={StyleSheet.absoluteFill} resizeMode="cover" />
                     : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
              </View>
              <Text style={car.posterTitle} numberOfLines={2}>{s.title}</Text>
              {s.genre && <Text style={car.posterSub}>{s.genre}</Text>}
            </TouchableOpacity>
          );
        })}
      </ScrollView>
    </View>
  );
}

function ChannelsCarousel({ label, channels, onPress }: { label: string; channels: Channel[]; onPress: (handle: string) => void }) {
  return (
    <View style={car.wrap}>
      <Text style={sec.label}>{label}</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={sec.row}>
        {channels.slice(0, 12).map((ch) => (
          <TouchableOpacity key={ch.id} style={car.channel} onPress={() => onPress(ch.handle)} activeOpacity={0.8}>
            <View style={car.avatar}>
              {ch.avatarUrl ? <Image source={{ uri: ch.avatarUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
                            : <Text style={car.avatarFallback}>{ch.name.charAt(0).toUpperCase()}</Text>}
            </View>
            <Text style={car.channelName} numberOfLines={1}>{ch.name}</Text>
            <Text style={car.channelSub}>{fmtCount(ch._count.videos)} videos</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>
    </View>
  );
}

function ShortsCarousel({ label, shorts, onPress }: { label: string; shorts: ShortVideo[]; onPress: (id: string) => void }) {
  return (
    <View style={car.wrap}>
      <Text style={sec.label}>{label}</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={sec.row}>
        {shorts.map((s) => (
          <TouchableOpacity key={s.id} style={car.short} onPress={() => onPress(s.id)} activeOpacity={0.8}>
            <View style={car.shortThumb}>
              {s.thumbnailUrl ? <Image source={{ uri: s.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
                              : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
              <View style={car.shortPlay}><Text style={{ fontSize: 18, color: '#fff' }}>▶</Text></View>
            </View>
            <Text style={car.posterTitle} numberOfLines={2}>{s.title}</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>
    </View>
  );
}

const car = StyleSheet.create({
  wrap:          { marginBottom: 24 },
  // Show poster
  poster:        { width: 110, marginRight: 12 },
  posterThumb:   { width: 110, height: 165, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  posterTitle:   { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
  posterSub:     { color: C.textSub, fontSize: 10, marginTop: 2 },
  // Channel
  channel:       { width: 80, alignItems: 'center', marginRight: 16 },
  avatar:        { width: 64, height: 64, borderRadius: 32, overflow: 'hidden', backgroundColor: C.surface2, alignItems: 'center', justifyContent: 'center', marginBottom: 6 },
  avatarFallback:{ fontSize: 22, fontWeight: '700', color: C.textSub },
  channelName:   { color: C.text, fontSize: 12, fontWeight: '600', textAlign: 'center' },
  channelSub:    { color: C.textMuted, fontSize: 10, marginTop: 2, textAlign: 'center' },
  // Short
  short:         { width: 120, marginRight: 12 },
  shortThumb:    { width: 120, height: 213, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  shortPlay:     { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.25)' },
});

const sec = StyleSheet.create({
  label: { fontSize: 16, fontWeight: '700', color: C.text, paddingHorizontal: 20, marginBottom: 12 },
  row:   { paddingHorizontal: 20 },
});

// ─── Feed builder ─────────────────────────────────────────────────────────────
// Merges videos with carousel slots at fixed intervals, matching web logic.

interface CarouselPool {
  shows:    Show[];
  channels: Channel[];
  shorts:   ShortVideo[];
}

function buildFeed(
  videos:   FeedVideo[],
  history:  HistoryItem[],
  carousels: CarouselPool,
  showHero:  boolean,
  heroShow:  Show | null,
  hasMore:   boolean,
): FeedItem[] {
  const items: FeedItem[] = [];

  if (showHero) {
    items.push({ key: '__hero', kind: 'hero', show: heroShow, fallback: videos[0] ?? null });
  }

  if (history.length > 0) {
    items.push({ key: '__continue', kind: 'continue', items: history });
  }

  const slots: Array<{ label: string; carouselKind: 'shows' | 'channels' | 'shorts' }> = [
    { label: 'Shows & Series',    carouselKind: 'shows'    },
    { label: 'Channels',          carouselKind: 'channels' },
    { label: 'Shorts',            carouselKind: 'shorts'   },
  ];
  let slotIdx = 0;

  videos.forEach((v, i) => {
    items.push({ key: `v-${v.id}`, kind: 'video', data: v });

    // After every CAROUSEL_EVERY videos, insert the next carousel slot
    const isCarouselPosition = (i + 1) % CAROUSEL_EVERY === 0;
    if (isCarouselPosition && slotIdx < slots.length) {
      const slot = slots[slotIdx++]!;
      // Only insert if there's data for this carousel type
      const hasData =
        (slot.carouselKind === 'shows'    && carousels.shows.length    > 0) ||
        (slot.carouselKind === 'channels' && carousels.channels.length > 0) ||
        (slot.carouselKind === 'shorts'   && carousels.shorts.length   > 0);

      if (hasData) {
        items.push({
          key:         `carousel-${slot.carouselKind}`,
          kind:        'carousel',
          label:       slot.label,
          carouselKind: slot.carouselKind,
          shows:       carousels.shows,
          channels:    carousels.channels,
          shorts:      carousels.shorts,
        });
      }
    }
  });

  items.push({ key: '__end', kind: hasMore ? 'loader' : 'end' });
  return items;
}

// ─── Main screen ──────────────────────────────────────────────────────────────

export default function HomeScreen() {
  const router = useRouter();

  const [videos,      setVideos]      = useState<FeedVideo[]>([]);
  const [cursor,      setCursor]      = useState<string | null>(null);
  const [hasMore,     setHasMore]     = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [carousels,   setCarousels]   = useState<CarouselPool>({ shows: [], channels: [], shorts: [] });
  const [history,     setHistory]     = useState<HistoryItem[]>([]);
  const [heroShow,    setHeroShow]    = useState<Show | null>(null);
  const [loading,     setLoading]     = useState(true);
  const [refreshing,  setRefreshing]  = useState(false);
  const loadingMoreRef = useRef(false);

  // ── Initial load ────────────────────────────────────────────────────────────
  const load = useCallback(async () => {
    try {
      const [feedRes, showsRes, channelsRes, shortsRes, histRes] = await Promise.allSettled([
        apiGet<{ videos: FeedVideo[]; nextCursor: string | null }>('/api/feed'),
        apiGet<{ shows: Show[] }>('/api/shows?take=12'),
        apiGet<Channel[]>('/api/channels'),
        apiGet<{ shorts: ShortVideo[] }>('/api/shorts?limit=10'),
        apiGet<HistoryItem[]>('/api/history'),
      ]);

      if (feedRes.status === 'fulfilled') {
        setVideos(feedRes.value.videos ?? []);
        setCursor(feedRes.value.nextCursor);
        setHasMore(!!feedRes.value.nextCursor);
      }

      const shows = showsRes.status === 'fulfilled' ? (showsRes.value.shows ?? []) : [];
      setHeroShow(shows[0] ?? null);

      setCarousels({
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

  // ── Load more (infinite scroll) ─────────────────────────────────────────────
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
    } catch {
      // non-fatal
    } finally {
      loadingMoreRef.current = false;
      setLoadingMore(false);
    }
  }, [cursor, hasMore]);

  // ── Build feed items ────────────────────────────────────────────────────────
  const feedItems: FeedItem[] = buildFeed(videos, history, carousels, true, heroShow, hasMore || loadingMore);

  // ── Render each item ────────────────────────────────────────────────────────
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
          <VideoRow
            video={item.data}
            onPress={() => router.push(`/(app)/watch/${item.data.id}` as any)}
          />
        );

      case 'carousel':
        if (item.carouselKind === 'shows' && item.shows?.length) {
          return (
            <ShowsCarousel
              label={item.label}
              shows={item.shows}
              onPress={(id) => router.push(`/(app)/show/${id}` as any)}
            />
          );
        }
        if (item.carouselKind === 'channels' && item.channels?.length) {
          return (
            <ChannelsCarousel
              label={item.label}
              channels={item.channels}
              onPress={(handle) => router.push(`/(app)/channel/${handle}` as any)}
            />
          );
        }
        if (item.carouselKind === 'shorts' && item.shorts?.length) {
          return (
            <ShortsCarousel
              label={item.label}
              shorts={item.shorts}
              onPress={(id) => router.push(`/(app)/watch/${id}` as any)}
            />
          );
        }
        return null;

      case 'loader':
        return (
          <View style={end.wrap}>
            <ActivityIndicator color={C.watch} size="small" />
          </View>
        );

      case 'end':
        return videos.length > 0
          ? <View style={end.wrap}><Text style={end.txt}>You're all caught up</Text></View>
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
        initialNumToRender={6}
        maxToRenderPerBatch={5}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={() => { setRefreshing(true); void load(); }}
            tintColor={C.watch}
          />
        }
        ListHeaderComponent={
          <View style={header.wrap}>
            <Text style={header.wordmark}>WeStreem</Text>
            <TouchableOpacity hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}>
              <Text style={header.icon}>🔍</Text>
            </TouchableOpacity>
          </View>
        }
        ListEmptyComponent={
          <View style={end.emptyWrap}>
            <Text style={end.emptyIcon}>📺</Text>
            <Text style={end.emptyTxt}>Nothing here yet.</Text>
            <Text style={end.emptySub}>Check back soon for new content.</Text>
          </View>
        }
        contentContainerStyle={{ paddingBottom: 48 }}
      />
    </Screen>
  );
}

const header = StyleSheet.create({
  wrap:     { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
              paddingHorizontal: 20, paddingTop: 16, paddingBottom: 8 },
  wordmark: { fontSize: 22, fontWeight: '800', color: C.text, letterSpacing: -0.5 },
  icon:     { fontSize: 20 },
});

const end = StyleSheet.create({
  wrap:     { alignItems: 'center', paddingVertical: 24 },
  txt:      { color: C.textMuted, fontSize: 12 },
  emptyWrap:{ alignItems: 'center', paddingTop: 60, paddingHorizontal: 32 },
  emptyIcon:{ fontSize: 48, marginBottom: 16 },
  emptyTxt: { color: C.text, fontSize: 16, fontWeight: '700', marginBottom: 6 },
  emptySub: { color: C.textMuted, fontSize: 13, textAlign: 'center' },
});
