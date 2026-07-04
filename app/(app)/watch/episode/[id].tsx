/**
 * Episode watch screen — full feature parity with web WatchClient.tsx (type="episode").
 *
 * Features:
 *  - Video player with resume (initialTime from /api/progress)
 *  - onTimeUpdate → POST /api/progress
 *  - Like / Dislike with { type: "like"|"dislike"|"remove" }
 *  - Show follow toggle
 *  - Share (native share sheet)
 *  - Expandable description
 *  - Director / Writer / Guest Stars
 *  - S·E badge, air date, duration, content rating, genre
 *  - Prev / Next episode navigation buttons
 *  - Episode list panel (collapsible accordion with season tabs)
 *  - Autoplay 5-second countdown overlay
 *  - Comments (load, post, delete, like)
 *  - Moment-likes passed to player
 *  - Paywall gate overlay (PPV / SVOD)
 *  - Rental info bar with countdown
 *  - Processing/transcoding banner
 *  - Breadcrumb (Home / Shows / Show Title / S·E)
 *  - Coming Soon locked screen
 */
import { useEffect, useRef, useState, useCallback } from 'react';
import {
  ScrollView, View, Text, TouchableOpacity, TextInput,
  ActivityIndicator, Image, Share, StyleSheet,
  KeyboardAvoidingView, Platform,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { VideoPlayer } from '@/components/VideoPlayer';
import { Screen } from '@/components/ui/Screen';
import { apiGet, apiPost, apiDelete } from '@/lib/api';
import { C } from '@/lib/constants';

// ─── Types ────────────────────────────────────────────────────────────────────

interface EpSibling {
  id: string;
  episodeNumber: number;
  seasonNumber: number;
  title: string;
  thumbnailUrl?: string | null;
  duration?: number | null;
  status: string;
  videoUrl?: string | null;
  comingSoon?: boolean;
}

interface SeasonEpisode {
  id: string;
  episodeNumber: number;
  title: string;
  thumbnailUrl?: string | null;
  duration?: number | null;
  status: string;
  videoUrl?: string | null;
  comingSoon?: boolean;
}

interface Season {
  id: string;
  seasonNumber: number;
  title?: string | null;
  episodes: SeasonEpisode[];
}

interface EpisodeDetail {
  id: string;
  title: string;
  description?: string | null;
  thumbnailUrl?: string | null;
  videoUrl?: string | null;
  cfStreamId?: string | null;
  duration?: number | null;
  views?: number;
  episodeNumber?: number;
  airDate?: string | null;
  director?: string | null;
  writer?: string | null;
  guestStars?: string[];
  comingSoon?: boolean;
  likes?: { userId: string; type: string }[];
  seasonId?: string;
  season: {
    seasonNumber: number;
    show: {
      id: string;
      title: string;
      coverUrl?: string | null;
      genre?: string | null;
      language?: string | null;
      contentRating?: string | null;
      seasons: Season[];
    };
  };
  // API-resolved fields
  prevEp?: EpSibling | null;
  nextEp?: EpSibling | null;
  isFollowing?: boolean;
  followerCount?: number;
  isNetworkMember?: boolean;
  paywallInfo?: PaywallInfo | null;
  rentalInfo?: RentalInfo | null;
}

interface PaywallInfo {
  productId: string;
  productName: string;
  entitlementType: 'PPV' | 'SVOD';
  price?: number;
  currency?: string;
  showId?: string;
  showTitle?: string;
}

interface RentalInfo {
  validTo: string | null;
  playbackExpiresAt: string | null;
  firstPlayedAt: string | null;
  playsUsed: number;
  maxPlays: number | null;
  playbackWindowSecs: number | null;
  productName: string;
}

interface Comment {
  id: string;
  content: string;
  likes?: number;
  createdAt?: string;
  user?: { id: string; name?: string | null; image?: string | null };
  replies?: Comment[];
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtCount(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000)     return `${(n / 1_000).toFixed(1)}K`;
  return n.toLocaleString();
}
function fmtDuration(s?: number | null): string | null {
  if (!s) return null;
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`
    : `${m}:${String(sec).padStart(2, '0')}`;
}
function timeAgo(iso?: string): string {
  if (!iso) return '';
  const s = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60)    return `${s}s ago`;
  if (s < 3600)  return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}
function useCountdown(targetIso: string | null): string | null {
  const [label, setLabel] = useState<string | null>(null);
  useEffect(() => {
    if (!targetIso) { setLabel(null); return; }
    function compute() {
      const diff = Math.max(0, Math.floor((new Date(targetIso!).getTime() - Date.now()) / 1000));
      if (diff <= 0) { setLabel('Expired'); return; }
      const d = Math.floor(diff / 86400);
      const h = Math.floor((diff % 86400) / 3600);
      const m = Math.floor((diff % 3600) / 60);
      const sec = diff % 60;
      if (d > 0)      setLabel(`${d}d ${h}h left`);
      else if (h > 0) setLabel(`${h}h ${m}m left`);
      else if (m > 0) setLabel(`${m}m ${sec}s left`);
      else            setLabel(`${sec}s left`);
    }
    compute();
    const id = setInterval(compute, 1000);
    return () => clearInterval(id);
  }, [targetIso]);
  return label;
}

// ─── Main screen ──────────────────────────────────────────────────────────────

export default function EpisodeWatchScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router  = useRouter();

  // ── Data ──
  const [ep,       setEp]       = useState<EpisodeDetail | null>(null);
  const [loading,  setLoading]  = useState(true);
  const [resumeAt, setResumeAt] = useState(0);

  // ── Like/dislike ──
  const [userLike,  setUserLike]  = useState<'like' | 'dislike' | null>(null);
  const [likeCount, setLikeCount] = useState(0);

  // ── Show follow ──
  const [following,    setFollowing]    = useState(false);
  const [followerCnt,  setFollowerCnt]  = useState(0);

  // ── Moment-likes ──
  const [likedSeconds, setLikedSeconds] = useState<number[]>([]);

  // ── Comments ──
  const [comments,     setComments]     = useState<Comment[]>([]);
  const [commentInput, setCommentInput] = useState('');
  const [commentCount, setCommentCount] = useState(0);
  const [replyTo,      setReplyTo]      = useState<Comment | null>(null);
  const [showAllComments, setShowAllComments] = useState(false);

  // ── UI ──
  const [showDesc,      setShowDesc]      = useState(false);
  const [autoNext,      setAutoNext]      = useState(true);
  const [countdown,     setCountdown]     = useState(0);
  const [epsOpen,       setEpsOpen]       = useState(false);
  const [activeSeason,  setActiveSeason]  = useState(1);

  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // ── Load episode + progress ──
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setEpsOpen(false);
    setCountdown(0);
    if (timerRef.current) { clearInterval(timerRef.current); timerRef.current = null; }

    Promise.allSettled([
      apiGet<EpisodeDetail>(`/api/episodes/${id}`),
      apiGet<{ seconds?: number } | null>(`/api/progress?episodeId=${id}`),
      apiGet<{ buckets?: number[]; userLikedSeconds?: number[] }>(`/api/episodes/${id}/moment-likes`),
    ]).then(([epRes, progRes, mlRes]) => {
      if (cancelled) return;

      if (epRes.status === 'fulfilled') {
        const data = epRes.value;
        setEp(data);
        setUserLike(
          (data.likes?.find(l => l.type === 'like') ? 'like' :
           data.likes?.find(l => l.type === 'dislike') ? 'dislike' : null)
        );
        setLikeCount(data.likes?.filter(l => l.type === 'like').length ?? 0);
        setFollowing(data.isFollowing ?? false);
        setFollowerCnt(data.followerCount ?? 0);
        setActiveSeason(data.season?.seasonNumber ?? 1);

        // Fetch comments separately
        apiGet<Comment[]>(`/api/episodes/${id}/comments`)
          .then(c => { if (!cancelled) { setComments(c); setCommentCount(c.length); } })
          .catch(() => {});
      }
      if (progRes.status === 'fulfilled' && progRes.value?.seconds && progRes.value.seconds > 10) {
        setResumeAt(progRes.value.seconds);
      }
      if (mlRes.status === 'fulfilled' && Array.isArray(mlRes.value?.userLikedSeconds)) {
        setLikedSeconds(mlRes.value.userLikedSeconds!);
      }
      setLoading(false);
    });
    return () => { cancelled = true; };
  }, [id]);

  useEffect(() => () => { if (timerRef.current) clearInterval(timerRef.current); }, []);

  // ── Progress tracking ──
  const handleTimeUpdate = useCallback((current: number, duration: number) => {
    if (duration <= 0) return;
    const percent = current / duration;
    apiPost('/api/progress', {
      episodeId: id,
      seconds: Math.floor(current),
      percent,
    }).catch(() => {});
  }, [id]);

  // ── Ended → autoplay countdown ──
  const handleEnded = useCallback(() => {
    const nextEp = ep?.nextEp;
    if (!autoNext || !nextEp?.videoUrl || nextEp.comingSoon) return;
    let secs = 5;
    setCountdown(secs);
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = setInterval(() => {
      secs -= 1;
      setCountdown(secs);
      if (secs <= 0) {
        clearInterval(timerRef.current!);
        timerRef.current = null;
        router.push(`/(app)/watch/episode/${nextEp.id}` as never);
      }
    }, 1000);
  }, [autoNext, ep, router]);

  // ── Like moment ──
  const handleLikeMoment = useCallback(async (timestampSec: number) => {
    const res = await apiPost<{ liked?: boolean }>(`/api/episodes/${id}/moment-likes`, { timestampSec });
    setLikedSeconds(prev =>
      res.liked ? [...prev, timestampSec] : prev.filter(s => s !== timestampSec)
    );
  }, [id]);

  // ── Like / dislike ──
  async function toggleLike(type: 'like' | 'dislike') {
    const sending = userLike === type ? 'remove' : type;
    const res = await apiPost<{ likes: number; dislikes: number; userLike: 'like' | 'dislike' | null }>(
      `/api/episodes/${id}/like`, { type: sending }
    );
    setLikeCount(res.likes);
    setUserLike(res.userLike ?? null);
  }

  // ── Show follow ──
  async function toggleFollow() {
    const showId = ep?.season?.show?.id;
    if (!showId) return;
    const res = await apiPost<{ subscribed: boolean; count: number }>(
      `/api/shows/${showId}/subscribe`
    );
    setFollowing(res.subscribed);
    setFollowerCnt(res.count);
  }

  // ── Share ──
  async function handleShare() {
    try {
      await Share.share({
        title: ep?.title ?? 'Watch on WeStreem',
        url: `https://www.westreem.com/watch/episode/${id}`,
      });
    } catch {}
  }

  // ── Comments ──
  async function postComment() {
    const content = commentInput.trim();
    if (!content) return;
    setCommentInput('');
    const body: { content: string; parentId?: string } = { content };
    if (replyTo) body.parentId = replyTo.id;
    setReplyTo(null);
    const c = await apiPost<Comment>(`/api/episodes/${id}/comments`, body);
    if (replyTo) {
      setComments(prev => prev.map(cm =>
        cm.id === replyTo.id ? { ...cm, replies: [...(cm.replies ?? []), c] } : cm
      ));
    } else {
      setComments(prev => [c, ...prev]);
      setCommentCount(n => n + 1);
    }
  }

  async function deleteComment(commentId: string) {
    await apiDelete(`/api/comments/${commentId}`);
    setComments(prev => prev.filter(c => c.id !== commentId));
    setCommentCount(n => n - 1);
  }

  async function likeComment(commentId: string) {
    await apiPost(`/api/comments/${commentId}`, { like: true });
    setComments(prev => prev.map(c =>
      c.id === commentId ? { ...c, likes: (c.likes ?? 0) + 1 } : c
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────────

  if (loading) {
    return (
      <Screen style={S.center}>
        <ActivityIndicator color={C.watch} size="large" />
      </Screen>
    );
  }

  if (!ep) {
    return (
      <Screen style={S.center}>
        <Text style={{ color: C.textSub, marginBottom: 16 }}>Episode not found</Text>
        <TouchableOpacity onPress={() => router.back()} style={S.backBtnFull}>
          <Text style={{ color: C.watch, fontWeight: '600' }}>← Go back</Text>
        </TouchableOpacity>
      </Screen>
    );
  }

  // Coming soon
  if (ep.comingSoon) {
    return (
      <Screen style={S.center}>
        <Text style={{ fontSize: 30, marginBottom: 16 }}>🔒</Text>
        <Text style={[S.comingSoonLabel, { color: C.watch }]}>Coming Soon</Text>
        <Text style={S.comingSoonTitle}>{ep.title}</Text>
        <Text style={{ color: C.textSub, fontSize: 13, textAlign: 'center', maxWidth: 280, marginBottom: 24 }}>
          This episode hasn't premiered yet. Check back when it's available.
        </Text>
        <TouchableOpacity
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          onPress={() => (router as any).push(`/shows/${ep.season?.show?.id}`)}
          style={S.backShowBtn}
        >
          <Text style={{ color: '#0a0a0f', fontWeight: '700', fontSize: 14 }}>
            ← Back to {ep.season?.show?.title}
          </Text>
        </TouchableOpacity>
      </Screen>
    );
  }

  const show       = ep.season?.show;
  const allSeasons = show?.seasons ?? [];
  const season     = ep.season;
  const paywallInfo = ep.paywallInfo ?? null;
  const rentalInfo  = ep.rentalInfo  ?? null;
  const isProcessing = !!(ep.cfStreamId && !ep.videoUrl);
  const prevEp = ep.prevEp;
  const nextEp = ep.nextEp;

  const prevLabel = prevEp
    ? (prevEp.seasonNumber !== season.seasonNumber
        ? `S${prevEp.seasonNumber}E${prevEp.episodeNumber}`
        : `E${prevEp.episodeNumber}`)
    : null;
  const nextLabel = nextEp?.videoUrl && !nextEp.comingSoon
    ? (nextEp.seasonNumber !== season.seasonNumber
        ? `S${nextEp.seasonNumber}E${nextEp.episodeNumber}`
        : `E${nextEp.episodeNumber}`)
    : null;

  const visibleCmts = comments.slice(0, showAllComments ? comments.length : 3);
  const activeSeasonObj = allSeasons.find(s => s.seasonNumber === activeSeason);

  return (
    <Screen>
      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <ScrollView
          style={{ flex: 1 }}
          contentContainerStyle={S.scrollContent}
          keyboardShouldPersistTaps="handled"
        >
          {/* ── Player ── */}
          <View style={S.playerWrap}>
            {isProcessing && (
              <View style={S.transcoding}>
                <Text style={S.transcodingTxt}>⚙ Transcoding — video will be available shortly</Text>
              </View>
            )}

            {ep.videoUrl ? (
              <VideoPlayer
                src={ep.videoUrl}
                poster={ep.thumbnailUrl ?? undefined}
                autoPlay
                initialTime={resumeAt}
                onTimeUpdate={handleTimeUpdate}
                onEnded={handleEnded}
                onLikeMoment={handleLikeMoment}
                onNext={nextEp?.videoUrl && !nextEp.comingSoon
                  ? () => router.push(`/(app)/watch/episode/${nextEp.id}` as never)
                  : undefined}
                userLikedSeconds={likedSeconds}
              />
            ) : (
              <View style={{ aspectRatio: 16 / 9, backgroundColor: '#000', justifyContent: 'center', alignItems: 'center' }}>
                <Text style={{ color: C.textSub, fontSize: 13 }}>
                  {isProcessing ? 'Processing…' : 'No video available'}
                </Text>
              </View>
            )}

            {/* Autoplay countdown */}
            {countdown > 0 && nextEp && (
              <AutoplayOverlay
                countdown={countdown}
                nextTitle={`${nextEp.seasonNumber !== season.seasonNumber ? `S${nextEp.seasonNumber} ` : ''}E${nextEp.episodeNumber} — ${nextEp.title}`}
                onPlayNow={() => {
                  clearInterval(timerRef.current!);
                  setCountdown(0);
                  router.push(`/(app)/watch/episode/${nextEp.id}` as never);
                }}
                onCancel={() => { clearInterval(timerRef.current!); setCountdown(0); }}
              />
            )}

            {/* Paywall gate */}
            {paywallInfo && (
              <PaywallOverlay
                info={paywallInfo}
                onBack={() => router.back()}
              />
            )}
          </View>

          {/* Rental info bar */}
          {rentalInfo && <RentalInfoBar info={rentalInfo} />}

          <View style={S.body}>
            {/* Breadcrumb */}
            <View style={S.breadcrumb}>
              <Text style={S.breadcrumbTxt}>Home</Text>
              <Text style={S.breadcrumbSep}>/</Text>
              <Text style={S.breadcrumbTxt}>Shows</Text>
              <Text style={S.breadcrumbSep}>/</Text>
              {show && (
                <>
                  {/* eslint-disable-next-line @typescript-eslint/no-explicit-any */}
                  <TouchableOpacity onPress={() => (router as any).push(`/shows/${show.id}`)}>
                    <Text style={S.breadcrumbTxt}>{show.title}</Text>
                  </TouchableOpacity>
                  <Text style={S.breadcrumbSep}>/</Text>
                </>
              )}
              <Text style={[S.breadcrumbTxt, { color: 'rgba(255,255,255,0.55)' }]}>
                S{season.seasonNumber}·E{ep.episodeNumber}
              </Text>
            </View>

            {/* Title */}
            <Text style={S.title}>{ep.title}</Text>

            {/* Metadata row */}
            <View style={S.metaRow}>
              {(ep.views ?? 0) > 0 && <Text style={S.metaChip}>{fmtCount(ep.views!)} views</Text>}
              {ep.airDate && (
                <Text style={S.metaChip}>
                  {new Date(ep.airDate).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })}
                </Text>
              )}
              {ep.duration && <Text style={S.metaChip}>{fmtDuration(ep.duration)}</Text>}
              <Text style={[S.metaChip, S.metaBadge]}>S{season.seasonNumber}·E{ep.episodeNumber}</Text>
              {show?.contentRating && (
                <View style={S.ratingBadge}>
                  <Text style={S.ratingTxt}>{show.contentRating}</Text>
                </View>
              )}
              {show?.genre && (
                <View style={S.genreBadge}>
                  <Text style={S.genreTxt}>{show.genre}</Text>
                </View>
              )}
            </View>

            {/* Description */}
            {ep.description && (
              <TouchableOpacity
                style={S.descBox}
                activeOpacity={0.8}
                onPress={() => setShowDesc(s => !s)}
              >
                <Text style={S.descTxt} numberOfLines={showDesc ? undefined : 2}>
                  {ep.description}
                </Text>
                {ep.description.length > 120 && (
                  <Text style={[S.descMore, { color: C.watch }]}>
                    {showDesc ? 'Show less' : '...more'}
                  </Text>
                )}
              </TouchableOpacity>
            )}

            {/* Director / Writer / Guest Stars */}
            {(ep.director || ep.writer || (ep.guestStars?.length ?? 0) > 0) && (
              <View style={S.creditsBox}>
                {ep.director && (
                  <View style={S.creditRow}>
                    <Text style={S.creditLabel}>DIRECTOR</Text>
                    <Text style={S.creditValue}>{ep.director}</Text>
                  </View>
                )}
                {ep.writer && (
                  <View style={S.creditRow}>
                    <Text style={S.creditLabel}>WRITER</Text>
                    <Text style={S.creditValue}>{ep.writer}</Text>
                  </View>
                )}
                {(ep.guestStars?.length ?? 0) > 0 && (
                  <View style={S.creditRow}>
                    <Text style={S.creditLabel}>GUEST STARS</Text>
                    <Text style={S.creditValue}>{ep.guestStars!.join(', ')}</Text>
                  </View>
                )}
              </View>
            )}

            {/* Source row: show cover + title + follow */}
            <View style={S.sourceSection}>
              <View style={S.sourceLeft}>
                {show?.coverUrl ? (
                  <Image source={{ uri: show.coverUrl }} style={S.showCover} borderRadius={8} />
                ) : (
                  <View style={[S.showCover, { backgroundColor: C.surface2, alignItems: 'center', justifyContent: 'center' }]}>
                    <Text style={{ color: C.watch, fontWeight: '700' }}>{show?.title?.[0]}</Text>
                  </View>
                )}
                <View style={{ flex: 1 }}>
                  <Text style={S.sourceName} numberOfLines={1}>{show?.title}</Text>
                  {followerCnt > 0 && (
                    <Text style={S.sourceFollowers}>{fmtCount(followerCnt)} follower{followerCnt !== 1 ? 's' : ''}</Text>
                  )}
                </View>
                <TouchableOpacity
                  onPress={toggleFollow}
                  style={[S.followBtn, following && S.followBtnActive]}
                >
                  <Text style={[S.followTxt, following && { color: 'rgba(255,255,255,0.7)' }]}>
                    {following ? 'Following' : 'Follow'}
                  </Text>
                </TouchableOpacity>
              </View>

              {/* Action buttons */}
              <View style={S.actions}>
                {/* Prev */}
                {prevLabel && prevEp && (
                  <TouchableOpacity
                    onPress={() => router.push(`/(app)/watch/episode/${prevEp.id}` as never)}
                    style={S.navBtn}
                  >
                    <Text style={S.navBtnTxt}>‹ {prevLabel}</Text>
                  </TouchableOpacity>
                )}

                {/* Next */}
                {nextLabel && nextEp && (
                  <TouchableOpacity
                    onPress={() => router.push(`/(app)/watch/episode/${nextEp.id}` as never)}
                    style={[S.navBtn, S.navBtnNext]}
                  >
                    <Text style={[S.navBtnTxt, { color: '#0a0a0f' }]}>{nextLabel} ›</Text>
                  </TouchableOpacity>
                )}

                {/* Like */}
                <TouchableOpacity
                  onPress={() => toggleLike('like')}
                  style={[S.actionBtn, userLike === 'like' && S.actionBtnActive]}
                >
                  <Text style={[S.actionIcon, userLike === 'like' && { color: C.watch }]}>♥</Text>
                  <Text style={[S.actionTxt, userLike === 'like' && { color: C.watch }]}>
                    {likeCount > 0 ? fmtCount(likeCount) : 'Like'}
                  </Text>
                </TouchableOpacity>

                {/* Dislike */}
                <TouchableOpacity
                  onPress={() => toggleLike('dislike')}
                  style={[S.actionBtn, userLike === 'dislike' && S.actionBtnActive]}
                >
                  <Text style={[S.actionIcon, userLike === 'dislike' && { color: 'rgba(255,255,255,0.85)' }]}>👎</Text>
                </TouchableOpacity>

                {/* Share */}
                <TouchableOpacity onPress={handleShare} style={S.actionBtn}>
                  <Text style={S.actionIcon}>↗</Text>
                  <Text style={S.actionTxt}>Share</Text>
                </TouchableOpacity>

                {/* Autoplay toggle */}
                <TouchableOpacity
                  onPress={() => setAutoNext(v => !v)}
                  style={[S.toggle, autoNext && S.toggleOn]}
                  activeOpacity={0.8}
                >
                  <View style={[S.toggleKnob, autoNext && S.toggleKnobOn]} />
                </TouchableOpacity>
              </View>
            </View>

            {/* ── Episode list accordion ── */}
            {allSeasons.length > 0 && (
              <View style={S.epsAccordion}>
                <TouchableOpacity
                  onPress={() => setEpsOpen(v => !v)}
                  style={S.epsHeader}
                  activeOpacity={0.8}
                >
                  <View style={S.epsHeaderLeft}>
                    {show?.coverUrl && (
                      <Image source={{ uri: show.coverUrl }} style={S.epsShowThumb} borderRadius={4} />
                    )}
                    <Text style={S.epsShowTitle} numberOfLines={1}>{show?.title}</Text>
                    <Text style={S.epsSeasonLabel}>· S{activeSeason}</Text>
                  </View>
                  <Text style={[S.epsChevron, epsOpen && S.epsChevronOpen]}>⌄</Text>
                </TouchableOpacity>

                {epsOpen && (
                  <View style={S.epsBody}>
                    {/* Season tabs */}
                    {allSeasons.length > 1 && (
                      <ScrollView
                        horizontal
                        showsHorizontalScrollIndicator={false}
                        contentContainerStyle={S.seasonTabs}
                      >
                        {allSeasons.map(s => (
                          <TouchableOpacity
                            key={s.seasonNumber}
                            onPress={() => setActiveSeason(s.seasonNumber)}
                            style={[
                              S.seasonTab,
                              activeSeason === s.seasonNumber && S.seasonTabActive,
                            ]}
                          >
                            <Text style={[
                              S.seasonTabTxt,
                              activeSeason === s.seasonNumber && S.seasonTabTxtActive,
                            ]}>
                              S{s.seasonNumber}
                            </Text>
                          </TouchableOpacity>
                        ))}
                      </ScrollView>
                    )}

                    {/* Episode rows for active season */}
                    {activeSeasonObj?.episodes.map(e => {
                      const isCurrent  = e.id === id;
                      const isPlayable = !!e.videoUrl && !e.comingSoon;
                      return (
                        <TouchableOpacity
                          key={e.id}
                          disabled={!isPlayable || isCurrent}
                          onPress={() => router.push(`/(app)/watch/episode/${e.id}` as never)}
                          style={[
                            S.epRow,
                            isCurrent  && S.epRowCurrent,
                            !isPlayable && { opacity: 0.45 },
                          ]}
                        >
                          <Text style={[
                            S.epNum,
                            isCurrent ? { color: C.watch } : { color: 'rgba(255,255,255,0.25)' },
                          ]}>
                            {isCurrent ? '▶' : e.episodeNumber}
                          </Text>
                          <View style={S.epThumbWrap}>
                            {e.thumbnailUrl ? (
                              <Image source={{ uri: e.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
                            ) : null}
                            {!isPlayable && (
                              <View style={S.epLockedOverlay}>
                                <Text style={{ color: 'rgba(255,255,255,0.5)', fontSize: 11 }}>🔒</Text>
                              </View>
                            )}
                            {fmtDuration(e.duration) && isPlayable && (
                              <View style={S.epDurBadge}>
                                <Text style={S.epDurTxt}>{fmtDuration(e.duration)}</Text>
                              </View>
                            )}
                          </View>
                          <View style={{ flex: 1, minWidth: 0 }}>
                            <Text
                              style={[S.epTitle, isCurrent && { color: C.text, fontWeight: '600' }]}
                              numberOfLines={2}
                            >
                              {e.title}
                            </Text>
                            {e.comingSoon && (
                              <View style={S.comingSoonBadge}>
                                <Text style={S.comingSoonBadgeTxt}>Coming Soon</Text>
                              </View>
                            )}
                          </View>
                        </TouchableOpacity>
                      );
                    })}
                  </View>
                )}
              </View>
            )}

            {/* ── Comments ── */}
            <View style={S.section}>
              <Text style={S.sectionTitle}>{commentCount} Comment{commentCount !== 1 ? 's' : ''}</Text>

              <View style={S.commentInput}>
                <TextInput
                  style={S.commentTextInput}
                  placeholder={replyTo ? `Reply to ${replyTo.user?.name ?? 'comment'}…` : 'Add a comment…'}
                  placeholderTextColor={C.textMuted}
                  value={commentInput}
                  onChangeText={setCommentInput}
                  multiline
                />
                <View style={S.commentActions}>
                  {replyTo && (
                    <TouchableOpacity onPress={() => setReplyTo(null)} style={{ paddingHorizontal: 10, paddingVertical: 5 }}>
                      <Text style={{ color: C.textSub, fontSize: 12 }}>Cancel</Text>
                    </TouchableOpacity>
                  )}
                  <TouchableOpacity
                    onPress={postComment}
                    disabled={!commentInput.trim()}
                    style={[S.postBtn, !commentInput.trim() && { opacity: 0.4 }]}
                  >
                    <Text style={S.postBtnTxt}>Post</Text>
                  </TouchableOpacity>
                </View>
              </View>

              {visibleCmts.map(c => (
                <CommentItem
                  key={c.id}
                  comment={c}
                  onReply={() => setReplyTo(c)}
                  onDelete={() => deleteComment(c.id)}
                  onLike={() => likeComment(c.id)}
                />
              ))}

              {comments.length > 3 && (
                <TouchableOpacity onPress={() => setShowAllComments(v => !v)} style={S.showMoreBtn}>
                  <Text style={{ color: C.watch, fontSize: 13, fontWeight: '600' }}>
                    {showAllComments ? 'Show less' : `Show all ${comments.length} comments`}
                  </Text>
                </TouchableOpacity>
              )}
            </View>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </Screen>
  );
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function AutoplayOverlay({
  countdown, nextTitle, onPlayNow, onCancel,
}: {
  countdown: number;
  nextTitle: string;
  onPlayNow: () => void;
  onCancel: () => void;
}) {
  return (
    <View style={Ov.container}>
      <Text style={Ov.hint}>Playing next in <Text style={Ov.num}>{countdown}</Text></Text>
      <Text style={Ov.nextTitle} numberOfLines={2}>{nextTitle}</Text>
      <View style={Ov.btnRow}>
        <TouchableOpacity onPress={onPlayNow} style={Ov.playBtn} activeOpacity={0.85}>
          <Text style={Ov.playTxt}>Play now</Text>
        </TouchableOpacity>
        <TouchableOpacity onPress={onCancel} style={Ov.cancelBtn} activeOpacity={0.85}>
          <Text style={Ov.cancelTxt}>Cancel</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

function PaywallOverlay({ info, onBack }: { info: PaywallInfo; onBack: () => void }) {
  const price = info.price != null && info.currency
    ? new Intl.NumberFormat('en-US', { style: 'currency', currency: info.currency }).format(info.price / 100)
    : null;
  return (
    <View style={Pw.container}>
      <View style={Pw.iconWrap}>
        <Text style={{ fontSize: 24 }}>🔒</Text>
      </View>
      <Text style={Pw.label}>
        {info.entitlementType === 'PPV' ? 'Rent to Watch' : 'Subscription Required'}
      </Text>
      <Text style={Pw.name}>{info.productName}</Text>
      {price && (
        <Text style={Pw.price}>
          {info.entitlementType === 'PPV' ? `${price} to rent` : `From ${price}`}
        </Text>
      )}
      {info.showId && (
        <TouchableOpacity onPress={onBack} style={Pw.backBtn}>
          <Text style={{ color: 'rgba(255,255,255,0.5)', fontSize: 13 }}>
            ← Back to {info.showTitle ?? 'show'}
          </Text>
        </TouchableOpacity>
      )}
    </View>
  );
}

function RentalInfoBar({ info }: { info: RentalInfo }) {
  const windowExpiry = info.playbackExpiresAt;
  const rentalExpiry = info.validTo;
  const activeExpiry = info.firstPlayedAt ? windowExpiry : rentalExpiry;
  const countdown    = useCountdown(activeExpiry);
  const started      = !!info.firstPlayedAt;
  const playsLeft    = info.maxPlays != null ? info.maxPlays - info.playsUsed : null;

  return (
    <View style={Ri.container}>
      <View style={Ri.badgeRow}>
        <View style={Ri.badge}>
          <Text style={Ri.badgeTxt}>Rental · {info.productName}</Text>
        </View>
        {countdown && (
          <Text style={Ri.info}>
            {started ? `Playback window: ` : `Rental expires in `}
            <Text style={{ color: 'rgba(255,255,255,0.85)', fontWeight: '600' }}>{countdown}</Text>
          </Text>
        )}
        {playsLeft !== null && (
          <Text style={[Ri.info, playsLeft === 0 && { color: C.danger }]}>
            {playsLeft > 0 ? `${playsLeft} play${playsLeft !== 1 ? 's' : ''} left` : 'No plays remaining'}
          </Text>
        )}
      </View>
    </View>
  );
}

function CommentItem({
  comment, onReply, onDelete, onLike,
}: {
  comment: Comment;
  onReply: () => void;
  onDelete: () => void;
  onLike: () => void;
}) {
  const [showReplies, setShowReplies] = useState(false);
  return (
    <View style={Cm.row}>
      <View style={Cm.avatar}>
        {comment.user?.image
          ? <Image source={{ uri: comment.user.image }} style={[StyleSheet.absoluteFill, { borderRadius: 14 }]} />
          : <Text style={Cm.avatarTxt}>{comment.user?.name?.[0]?.toUpperCase() ?? '?'}</Text>}
      </View>
      <View style={{ flex: 1 }}>
        <View style={Cm.header}>
          <Text style={Cm.name}>{comment.user?.name ?? 'User'}</Text>
          {comment.createdAt && <Text style={Cm.time}>{timeAgo(comment.createdAt)}</Text>}
        </View>
        <Text style={Cm.content}>{comment.content}</Text>
        <View style={Cm.actions}>
          <TouchableOpacity onPress={onLike} style={Cm.actionBtn}>
            <Text style={Cm.actionTxt}>♥ {comment.likes ?? 0}</Text>
          </TouchableOpacity>
          <TouchableOpacity onPress={onReply} style={Cm.actionBtn}>
            <Text style={Cm.actionTxt}>Reply</Text>
          </TouchableOpacity>
          <TouchableOpacity onPress={onDelete} style={Cm.actionBtn}>
            <Text style={[Cm.actionTxt, { color: C.danger }]}>Delete</Text>
          </TouchableOpacity>
        </View>
        {(comment.replies?.length ?? 0) > 0 && (
          <TouchableOpacity onPress={() => setShowReplies(v => !v)} style={{ marginTop: 4 }}>
            <Text style={{ color: C.watch, fontSize: 11, fontWeight: '600' }}>
              {showReplies ? 'Hide replies' : `${comment.replies!.length} repl${comment.replies!.length > 1 ? 'ies' : 'y'}`}
            </Text>
          </TouchableOpacity>
        )}
        {showReplies && comment.replies?.map(r => (
          <View key={r.id} style={Cm.replyRow}>
            <View style={Cm.replyAvatar}>
              <Text style={Cm.avatarTxt}>{r.user?.name?.[0]?.toUpperCase() ?? '?'}</Text>
            </View>
            <View style={{ flex: 1 }}>
              <Text style={Cm.name}>{r.user?.name ?? 'User'}</Text>
              <Text style={Cm.content}>{r.content}</Text>
            </View>
          </View>
        ))}
      </View>
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const S = StyleSheet.create({
  center:        { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 20 },
  backBtnFull:   { paddingHorizontal: 20, paddingVertical: 10, borderRadius: 20, borderWidth: 1, borderColor: C.border },
  scrollContent: { paddingBottom: 80 },
  playerWrap:    { width: '100%', backgroundColor: '#000', position: 'relative' },
  transcoding: {
    position: 'absolute', top: 12, left: 0, right: 0, zIndex: 20, alignItems: 'center',
  },
  transcodingTxt: {
    backgroundColor: 'rgba(251,191,36,0.15)', color: '#fbbf24',
    fontSize: 11, fontWeight: '600', paddingHorizontal: 12, paddingVertical: 5,
    borderRadius: 20, borderWidth: 1, borderColor: 'rgba(251,191,36,0.3)',
  },

  comingSoonLabel: { fontSize: 11, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 1.5, marginBottom: 8 },
  comingSoonTitle: { fontSize: 22, fontWeight: '800', color: C.text, textAlign: 'center', marginBottom: 8 },
  backShowBtn:     { paddingHorizontal: 24, paddingVertical: 12, borderRadius: 24, backgroundColor: C.watch },

  body: { paddingHorizontal: 16, paddingTop: 12 },

  breadcrumb: { flexDirection: 'row', alignItems: 'center', flexWrap: 'wrap', marginBottom: 8, gap: 4 },
  breadcrumbTxt: { fontSize: 11, color: 'rgba(255,255,255,0.35)' },
  breadcrumbSep: { fontSize: 11, color: 'rgba(255,255,255,0.2)' },

  title: { fontSize: 19, fontWeight: '800', color: C.text, lineHeight: 26, marginBottom: 6 },

  metaRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, alignItems: 'center', marginBottom: 10 },
  metaChip: { fontSize: 12, color: C.textSub },
  metaBadge:   { color: '#fff', fontWeight: '600' },
  ratingBadge: { borderWidth: 1, borderColor: C.border2, borderRadius: 4, paddingHorizontal: 6, paddingVertical: 2 },
  ratingTxt:   { color: 'rgba(255,255,255,0.75)', fontSize: 11, fontWeight: '500' },
  genreBadge:  { borderRadius: 20, paddingHorizontal: 8, paddingVertical: 3, backgroundColor: `${C.watch}20` },
  genreTxt:    { color: C.watch, fontSize: 11, fontWeight: '600' },

  descBox:  { backgroundColor: C.surface2, borderRadius: 10, padding: 12, marginBottom: 12 },
  descTxt:  { color: C.textSub, fontSize: 13, lineHeight: 19 },
  descMore: { fontSize: 12, fontWeight: '600', marginTop: 4 },

  creditsBox: { backgroundColor: C.surface2, borderRadius: 10, padding: 12, marginBottom: 12, gap: 4 },
  creditRow:  { flexDirection: 'row', gap: 8 },
  creditLabel: { color: 'rgba(255,255,255,0.25)', fontSize: 10, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.8, width: 72 },
  creditValue: { color: 'rgba(255,255,255,0.6)', fontSize: 12, flex: 1 },

  sourceSection: { marginBottom: 12 },
  sourceLeft: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 10 },
  showCover:  { width: 40, height: 40, borderRadius: 8 },
  sourceName: { fontSize: 14, fontWeight: '600', color: C.text, flex: 1 },
  sourceFollowers: { fontSize: 11, color: C.textMuted, marginTop: 1 },
  followBtn:  { paddingHorizontal: 14, paddingVertical: 7, borderRadius: 20, backgroundColor: C.watch },
  followBtnActive: { backgroundColor: C.surface2, borderWidth: 1, borderColor: C.border },
  followTxt:  { fontSize: 13, fontWeight: '600', color: '#0a0a0f' },

  actions: { flexDirection: 'row', gap: 8, flexWrap: 'wrap', alignItems: 'center' },
  navBtn:  {
    paddingHorizontal: 12, paddingVertical: 7, borderRadius: 20,
    backgroundColor: C.surface, borderWidth: 1, borderColor: C.border,
  },
  navBtnNext: { backgroundColor: C.watch, borderColor: C.watch },
  navBtnTxt:  { fontSize: 12, color: C.textSub, fontWeight: '500' },

  actionBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 12, paddingVertical: 7,
    borderRadius: 20, backgroundColor: C.surface,
    borderWidth: 1, borderColor: C.border,
  },
  actionBtnActive: { backgroundColor: C.surface2, borderColor: C.border2 },
  actionIcon: { fontSize: 14, color: C.textSub },
  actionTxt:  { fontSize: 12, color: C.textSub, fontWeight: '500' },

  toggle: {
    width: 36, height: 20, borderRadius: 10, backgroundColor: 'rgba(255,255,255,0.12)',
    justifyContent: 'center', paddingHorizontal: 2,
  },
  toggleOn:      { backgroundColor: C.watch },
  toggleKnob:    { width: 16, height: 16, borderRadius: 8, backgroundColor: '#fff', alignSelf: 'flex-start' },
  toggleKnobOn:  { alignSelf: 'flex-end' },

  // Episode accordion
  epsAccordion: { borderRadius: 12, borderWidth: 1, borderColor: C.border, overflow: 'hidden', marginBottom: 16 },
  epsHeader: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: 14, paddingVertical: 12,
    backgroundColor: C.surface,
  },
  epsHeaderLeft: { flexDirection: 'row', alignItems: 'center', gap: 8, flex: 1, minWidth: 0 },
  epsShowThumb:  { width: 24, height: 24, borderRadius: 4 },
  epsShowTitle:  { fontSize: 13, fontWeight: '600', color: C.text, flex: 1 },
  epsSeasonLabel: { fontSize: 12, color: C.textMuted },
  epsChevron:    { color: 'rgba(255,255,255,0.4)', fontSize: 16 },
  epsChevronOpen: { transform: [{ rotate: '180deg' }] },

  epsBody: { backgroundColor: C.surface, borderTopWidth: 1, borderTopColor: C.border },
  seasonTabs: { paddingHorizontal: 12, paddingVertical: 8, gap: 6 },
  seasonTab:       { paddingHorizontal: 12, paddingVertical: 5, borderRadius: 20, backgroundColor: C.surface2 },
  seasonTabActive: { backgroundColor: C.watch },
  seasonTabTxt:    { fontSize: 12, color: C.textSub, fontWeight: '500' },
  seasonTabTxtActive: { color: '#0a0a0f', fontWeight: '700' },

  epRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingHorizontal: 12, paddingVertical: 8,
    borderTopWidth: 1, borderTopColor: C.border,
    borderLeftWidth: 2, borderLeftColor: 'transparent',
  },
  epRowCurrent: { backgroundColor: `${C.watch}0D`, borderLeftColor: C.watch },
  epNum: { width: 18, textAlign: 'center', fontSize: 11, fontWeight: '600', flexShrink: 0 },
  epThumbWrap: {
    width: 72, aspectRatio: 16 / 9, borderRadius: 6,
    backgroundColor: C.surface2, overflow: 'hidden',
    position: 'relative', flexShrink: 0,
  },
  epLockedOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(0,0,0,0.55)',
    alignItems: 'center', justifyContent: 'center',
  },
  epDurBadge: {
    position: 'absolute', bottom: 2, right: 2,
    backgroundColor: 'rgba(0,0,0,0.8)', borderRadius: 3,
    paddingHorizontal: 3, paddingVertical: 1,
  },
  epDurTxt: { color: '#fff', fontSize: 9, fontWeight: '600' },
  epTitle:  { fontSize: 12, color: 'rgba(255,255,255,0.7)', lineHeight: 16 },

  comingSoonBadge: {
    marginTop: 3, alignSelf: 'flex-start',
    backgroundColor: 'rgba(251,191,36,0.15)',
    borderRadius: 20, paddingHorizontal: 6, paddingVertical: 2,
  },
  comingSoonBadgeTxt: { color: '#fbbf24', fontSize: 9, fontWeight: '700' },

  section:       { marginTop: 16 },
  sectionTitle:  { fontSize: 15, fontWeight: '700', color: C.text, marginBottom: 10 },

  commentInput: {
    backgroundColor: C.surface, borderRadius: 10,
    borderWidth: 1, borderColor: C.border, marginBottom: 14, padding: 10,
  },
  commentTextInput: { color: C.text, fontSize: 13, minHeight: 36, maxHeight: 80 },
  commentActions:   { flexDirection: 'row', justifyContent: 'flex-end', marginTop: 6, gap: 8 },
  postBtn:    { backgroundColor: C.watch, borderRadius: 16, paddingHorizontal: 14, paddingVertical: 6 },
  postBtnTxt: { color: '#0a0a0f', fontSize: 12, fontWeight: '700' },

  showMoreBtn: {
    alignItems: 'center', paddingVertical: 10,
    borderTopWidth: 1, borderTopColor: C.border, marginTop: 6,
  },
});

const Ov = StyleSheet.create({
  container: {
    ...StyleSheet.absoluteFillObject, backgroundColor: 'rgba(0,0,0,0.82)',
    alignItems: 'center', justifyContent: 'center', zIndex: 20, gap: 10, padding: 24,
  },
  hint:     { color: 'rgba(255,255,255,0.5)', fontSize: 13 },
  num:      { color: '#fff', fontWeight: '800', fontSize: 26 },
  nextTitle:{ color: '#fff', fontWeight: '600', fontSize: 14, textAlign: 'center', maxWidth: 260 },
  btnRow:   { flexDirection: 'row', gap: 10, marginTop: 6 },
  playBtn:  { paddingHorizontal: 20, paddingVertical: 10, borderRadius: 24, backgroundColor: C.watch },
  playTxt:  { color: '#0a0a0f', fontWeight: '700', fontSize: 14 },
  cancelBtn:{ paddingHorizontal: 20, paddingVertical: 10, borderRadius: 24, backgroundColor: 'rgba(255,255,255,0.10)' },
  cancelTxt:{ color: '#fff', fontSize: 14 },
});

const Pw = StyleSheet.create({
  container: {
    ...StyleSheet.absoluteFillObject, backgroundColor: 'rgba(0,0,0,0.92)',
    alignItems: 'center', justifyContent: 'center', zIndex: 30, gap: 10, padding: 24,
  },
  iconWrap: {
    width: 56, height: 56, borderRadius: 28,
    backgroundColor: `${C.watch}22`, alignItems: 'center', justifyContent: 'center',
  },
  label: { color: C.watch, fontSize: 11, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 1.5 },
  name:  { color: C.text, fontSize: 20, fontWeight: '800', textAlign: 'center' },
  price: { color: C.textSub, fontSize: 13 },
  backBtn: { marginTop: 10, paddingVertical: 6 },
});

const Ri = StyleSheet.create({
  container: {
    marginHorizontal: 0, paddingHorizontal: 14, paddingVertical: 8,
    backgroundColor: `${C.watch}1A`,
    borderBottomWidth: 1, borderBottomColor: `${C.watch}33`,
  },
  badgeRow: { flexDirection: 'row', alignItems: 'center', flexWrap: 'wrap', gap: 10 },
  badge: {
    backgroundColor: `${C.watch}33`, borderRadius: 4,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  badgeTxt: { color: C.watch, fontSize: 10, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.8 },
  info: { color: 'rgba(255,255,255,0.6)', fontSize: 11 },
});

const Cm = StyleSheet.create({
  row:     { flexDirection: 'row', gap: 10, marginBottom: 14 },
  avatar:  { width: 28, height: 28, borderRadius: 14, backgroundColor: C.surface2, overflow: 'hidden', alignItems: 'center', justifyContent: 'center', flexShrink: 0 },
  avatarTxt: { color: C.watch, fontSize: 12, fontWeight: '700' },
  header:  { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 3 },
  name:    { color: C.text, fontSize: 12, fontWeight: '600' },
  time:    { color: C.textMuted, fontSize: 11 },
  content: { color: C.textSub, fontSize: 13, lineHeight: 18 },
  actions: { flexDirection: 'row', gap: 10, marginTop: 5 },
  actionBtn: { paddingVertical: 2 },
  actionTxt: { color: C.textMuted, fontSize: 11, fontWeight: '500' },
  replyRow:  { flexDirection: 'row', gap: 8, marginTop: 8, paddingLeft: 8 },
  replyAvatar: { width: 22, height: 22, borderRadius: 11, backgroundColor: C.surface2, alignItems: 'center', justifyContent: 'center' },
});
