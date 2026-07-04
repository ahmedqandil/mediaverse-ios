/**
 * Home screen — mirrors the WeStreem web homepage structure.
 *
 * Sections (in order):
 *   1. Hero banner        — latest featured show (or first feed video fallback)
 *   2. Continue Watching  — from watch history (hidden if empty)
 *   3. Just Added         — paginated video feed
 *   4. Shows & Series     — shows catalogue
 */
import { useEffect, useState, useCallback } from 'react';
import {
  View, Text, Image, ScrollView, TouchableOpacity,
  ActivityIndicator, StyleSheet, RefreshControl,
  Dimensions,
} from 'react-native';
import { useRouter } from 'expo-router';
import { Screen } from '@/components/ui/Screen';
import { apiGet } from '@/lib/api';
import { C } from '@/lib/constants';

const { width: SCREEN_W } = Dimensions.get('window');

// ── API types ─────────────────────────────────────────────────────────────────

interface FeedVideo {
  id:           string;
  title:        string;
  thumbnailUrl: string | null;
  duration:     number | null;
  views:        number;
  createdAt:    string;
  channel:      { id: string; name: string; handle: string; avatarUrl: string | null } | null;
}

interface Show {
  id:          string;
  title:       string;
  coverUrl:    string | null;
  bannerUrl:   string | null;
  genre:       string | null;
  description: string | null;
}

interface HistoryItem {
  id:      string;
  seconds: number;
  percent: number;
  video: {
    id:           string;
    title:        string;
    thumbnailUrl: string | null;
    duration:     number | null;
  } | null;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function fmtDuration(secs: number | null): string {
  if (!secs) return '';
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${m}:${String(s).padStart(2, '0')}`;
}

// ── Section header ────────────────────────────────────────────────────────────

function SectionHeader({ title }: { title: string }) {
  return <Text style={sh.title}>{title}</Text>;
}
const sh = StyleSheet.create({
  title: { fontSize: 16, fontWeight: '700', color: C.text, paddingHorizontal: 20, marginBottom: 12 },
});

// ── Video card (landscape 16:9) ───────────────────────────────────────────────

function VideoCard({ video, onPress }: { video: FeedVideo; onPress: () => void }) {
  return (
    <TouchableOpacity style={vc.card} onPress={onPress} activeOpacity={0.8}>
      <View style={vc.thumb}>
        {video.thumbnailUrl
          ? <Image source={{ uri: video.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
        {video.duration != null && (
          <View style={vc.dur}>
            <Text style={vc.durTxt}>{fmtDuration(video.duration)}</Text>
          </View>
        )}
      </View>
      <Text style={vc.title} numberOfLines={2}>{video.title}</Text>
      {video.channel && <Text style={vc.channel} numberOfLines={1}>{video.channel.name}</Text>}
    </TouchableOpacity>
  );
}
const vc = StyleSheet.create({
  card:    { width: 160, marginRight: 12 },
  thumb:   { width: 160, height: 90, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  dur:     { position: 'absolute', bottom: 4, right: 6, backgroundColor: 'rgba(0,0,0,0.75)', borderRadius: 4, paddingHorizontal: 4, paddingVertical: 1 },
  durTxt:  { color: '#fff', fontSize: 10, fontWeight: '600' },
  title:   { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
  channel: { color: C.textSub, fontSize: 11, marginTop: 2 },
});

// ── Continue-watching card (with progress bar) ────────────────────────────────

function ContinueCard({ item, onPress }: { item: HistoryItem; onPress: () => void }) {
  const video = item.video;
  if (!video) return null;
  const pct = Math.min(Math.max(item.percent, 0), 1);
  return (
    <TouchableOpacity style={cw.card} onPress={onPress} activeOpacity={0.8}>
      <View style={cw.thumb}>
        {video.thumbnailUrl
          ? <Image source={{ uri: video.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          : <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface2 }]} />}
        <View style={cw.overlay}>
          <Text style={cw.playIcon}>▶</Text>
        </View>
        <View style={cw.barBg}>
          <View style={[cw.barFill, { width: `${(pct * 100).toFixed(0)}%` as any }]} />
        </View>
      </View>
      <Text style={cw.title} numberOfLines={2}>{video.title}</Text>
    </TouchableOpacity>
  );
}
const cw = StyleSheet.create({
  card:    { width: 160, marginRight: 12 },
  thumb:   { width: 160, height: 90, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  overlay: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.3)' },
  playIcon:{ fontSize: 22, color: '#fff' },
  barBg:   { position: 'absolute', bottom: 0, left: 0, right: 0, height: 3, backgroundColor: 'rgba(255,255,255,0.2)' },
  barFill: { height: 3, backgroundColor: C.watch },
  title:   { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
});

// ── Show card (portrait 2:3) ──────────────────────────────────────────────────

function ShowCard({ show, onPress }: { show: Show; onPress: () => void }) {
  const img = show.coverUrl ?? show.bannerUrl;
  return (
    <TouchableOpacity style={sc.card} onPress={onPress} activeOpacity={0.8}>
      <View style={sc.poster}>
        {img
          ? <Image source={{ uri: img }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          : (
            <View style={[StyleSheet.absoluteFill, sc.fallback]}>
              <Text style={sc.fallbackTxt} numberOfLines={3}>{show.title}</Text>
            </View>
          )}
      </View>
      <Text style={sc.title} numberOfLines={2}>{show.title}</Text>
      {show.genre && <Text style={sc.genre}>{show.genre}</Text>}
    </TouchableOpacity>
  );
}
const sc = StyleSheet.create({
  card:       { width: 120, marginRight: 12 },
  poster:     { width: 120, height: 180, borderRadius: 10, overflow: 'hidden', backgroundColor: C.surface2 },
  fallback:   { alignItems: 'center', justifyContent: 'center', padding: 8 },
  fallbackTxt:{ color: C.textSub, fontSize: 11, textAlign: 'center' },
  title:      { color: C.text, fontSize: 12, fontWeight: '600', marginTop: 6, lineHeight: 17 },
  genre:      { color: C.textSub, fontSize: 10, marginTop: 2 },
});

// ── Hero banner ───────────────────────────────────────────────────────────────

function HeroBanner({ show, fallbackVideo, onWatch }: {
  show:          Show | null;
  fallbackVideo: FeedVideo | null;
  onWatch:       () => void;
}) {
  const imgUri = show?.bannerUrl ?? show?.coverUrl ?? fallbackVideo?.thumbnailUrl ?? null;
  const title  = show?.title ?? fallbackVideo?.title ?? '';
  const badge  = show ? 'Featured Series' : 'Just Added';

  return (
    <View style={hb.wrap}>
      {imgUri
        ? <Image source={{ uri: imgUri }} style={StyleSheet.absoluteFill} resizeMode="cover" />
        : <View style={[StyleSheet.absoluteFill, hb.fallback]} />}

      {/* Dark gradient from bottom */}
      <View style={hb.grad} />

      <View style={hb.content}>
        <Text style={hb.badge}>{badge}</Text>
        <Text style={hb.title} numberOfLines={2}>{title}</Text>
        {show?.genre ? <Text style={hb.meta}>{show.genre}</Text> : null}
        <View style={hb.btns}>
          <TouchableOpacity style={hb.watchBtn} onPress={onWatch} activeOpacity={0.85}>
            <Text style={hb.watchBtnTxt}>▶  Watch Now</Text>
          </TouchableOpacity>
        </View>
      </View>
    </View>
  );
}

const HERO_H = Math.round(SCREEN_W * (9 / 16));
const hb = StyleSheet.create({
  wrap:       { width: SCREEN_W, height: HERO_H, marginBottom: 28 },
  fallback:   { backgroundColor: C.surface2 },
  grad:       { position: 'absolute', bottom: 0, left: 0, right: 0, height: HERO_H,
                backgroundColor: 'rgba(10,10,15,0.6)' },
  content:    { position: 'absolute', bottom: 0, left: 0, right: 0, padding: 20, paddingBottom: 22 },
  badge:      { fontSize: 10, fontWeight: '700', color: C.watch, letterSpacing: 1.5, textTransform: 'uppercase', marginBottom: 6 },
  title:      { fontSize: 22, fontWeight: '800', color: C.text, lineHeight: 28, marginBottom: 4 },
  meta:       { fontSize: 12, color: 'rgba(255,255,255,0.5)', marginBottom: 12 },
  btns:       { flexDirection: 'row', gap: 10 },
  watchBtn:   { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 22, paddingVertical: 10,
                borderRadius: 100, backgroundColor: C.watch },
  watchBtnTxt:{ fontSize: 13, fontWeight: '700', color: '#0a0a12' },
});

// ── Main screen ───────────────────────────────────────────────────────────────

export default function HomeScreen() {
  const router = useRouter();

  const [feedVideos, setFeedVideos] = useState<FeedVideo[]>([]);
  const [shows,      setShows]      = useState<Show[]>([]);
  const [history,    setHistory]    = useState<HistoryItem[]>([]);
  const [loading,    setLoading]    = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    try {
      const [feedRes, showsRes, histRes] = await Promise.allSettled([
        apiGet<{ videos: FeedVideo[] }>('/api/feed'),
        apiGet<{ shows: Show[] }>('/api/shows?take=12'),
        apiGet<HistoryItem[]>('/api/history'),
      ]);

      if (feedRes.status  === 'fulfilled') setFeedVideos(feedRes.value.videos  ?? []);
      if (showsRes.status === 'fulfilled') setShows(showsRes.value.shows ?? []);
      if (histRes.status  === 'fulfilled') {
        setHistory(
          (histRes.value ?? []).filter(
            (h) => h.video && h.percent > 0.02 && h.percent < 0.95,
          ),
        );
      }
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  if (loading) {
    return (
      <Screen style={s.center}>
        <ActivityIndicator color={C.watch} size="large" />
      </Screen>
    );
  }

  const featuredShow   = shows[0]      ?? null;
  const heroFallback   = feedVideos[0] ?? null;
  const hasContent     = feedVideos.length > 0 || shows.length > 0;

  return (
    <Screen>
      <ScrollView
        contentContainerStyle={s.scroll}
        showsVerticalScrollIndicator={false}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={() => { setRefreshing(true); void load(); }}
            tintColor={C.watch}
          />
        }
      >
        {/* ── Header ─────────────────────────────────────────────────────── */}
        <View style={s.header}>
          <Text style={s.wordmark}>WeStreem</Text>
          <TouchableOpacity hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}>
            <Text style={s.searchIcon}>🔍</Text>
          </TouchableOpacity>
        </View>

        {/* ── Hero ───────────────────────────────────────────────────────── */}
        {(featuredShow || heroFallback) && (
          <HeroBanner
            show={featuredShow}
            fallbackVideo={heroFallback}
            onWatch={() => {
              if (featuredShow) router.push(`/(app)/show/${featuredShow.id}` as any);
              else if (heroFallback) router.push(`/(app)/watch/${heroFallback.id}` as any);
            }}
          />
        )}

        {/* ── Continue Watching ──────────────────────────────────────────── */}
        {history.length > 0 && (
          <View style={s.section}>
            <SectionHeader title="Continue Watching" />
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.row}>
              {history.slice(0, 10).map((item) => (
                <ContinueCard
                  key={item.id}
                  item={item}
                  onPress={() => router.push(`/(app)/watch/${item.video!.id}` as any)}
                />
              ))}
            </ScrollView>
          </View>
        )}

        {/* ── Just Added ─────────────────────────────────────────────────── */}
        {feedVideos.length > 0 && (
          <View style={s.section}>
            <SectionHeader title="Just Added" />
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.row}>
              {feedVideos.map((v) => (
                <VideoCard
                  key={v.id}
                  video={v}
                  onPress={() => router.push(`/(app)/watch/${v.id}` as any)}
                />
              ))}
            </ScrollView>
          </View>
        )}

        {/* ── Shows & Series ─────────────────────────────────────────────── */}
        {shows.length > 0 && (
          <View style={s.section}>
            <SectionHeader title="Shows & Series" />
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.row}>
              {shows.map((show) => (
                <ShowCard
                  key={show.id}
                  show={show}
                  onPress={() => router.push(`/(app)/show/${show.id}` as any)}
                />
              ))}
            </ScrollView>
          </View>
        )}

        {/* ── Empty state ─────────────────────────────────────────────────── */}
        {!hasContent && (
          <View style={s.empty}>
            <Text style={s.emptyIcon}>📺</Text>
            <Text style={s.emptyTxt}>Nothing here yet.</Text>
            <Text style={s.emptySub}>Check back soon for new content.</Text>
          </View>
        )}
      </ScrollView>
    </Screen>
  );
}

const s = StyleSheet.create({
  center:     { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll:     { paddingBottom: 48 },
  header:     { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
                paddingHorizontal: 20, paddingTop: 16, paddingBottom: 8 },
  wordmark:   { fontSize: 22, fontWeight: '800', color: C.text, letterSpacing: -0.5 },
  searchIcon: { fontSize: 20 },
  section:    { marginBottom: 28 },
  row:        { paddingHorizontal: 20 },
  empty:      { alignItems: 'center', paddingTop: 60, paddingHorizontal: 32 },
  emptyIcon:  { fontSize: 48, marginBottom: 16 },
  emptyTxt:   { color: C.text, fontSize: 16, fontWeight: '700', marginBottom: 6 },
  emptySub:   { color: C.textMuted, fontSize: 13, textAlign: 'center' },
});
