/**
 * Video watch screen — full feature parity with web WatchClient.tsx (type="video").
 *
 * Features:
 *  - Video player with resume (initialTime from /api/progress)
 *  - onTimeUpdate → POST /api/progress for watch history
 *  - Like / Dislike with { type: "like"|"dislike"|"remove" } API shape
 *  - Channel subscribe / show follow toggle
 *  - Share (native share sheet)
 *  - Expandable description
 *  - Director/Writer/Guest Stars (video-level fields)
 *  - Linked clip / linked episode cards
 *  - Up Next list with autoplay toggle
 *  - Autoplay 5-second countdown overlay
 *  - Comments (load, post, delete, like)
 *  - Moment-likes passed to player
 *  - Markers loaded from API
 *  - Paywall gate overlay (PPV / SVOD)
 *  - Processing/transcoding banner
 *  - Breadcrumb (show-linked videos)
 *  - Views + date metadata
 */
import { useEffect, useRef, useState, useCallback } from 'react';
import {
  ScrollView, View, Text, TouchableOpacity, TextInput,
  ActivityIndicator, Image, Share, StyleSheet, Animated,
  KeyboardAvoidingView, Platform,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { VideoPlayer } from '@/components/VideoPlayer';
import { Screen } from '@/components/ui/Screen';
import { apiGet, apiPost, apiDelete } from '@/lib/api';
import { C } from '@/lib/constants';

// ─── Types ────────────────────────────────────────────────────────────────────

interface VideoDetail {
  id: string;
  title: string;
  description?: string | null;
  thumbnailUrl?: string | null;
  videoUrl?: string | null;
  cfStreamId?: string | null;
  duration?: number | null;
  views?: number;
  type?: string;
  createdAt?: string;
  channel?: {
    id: string;
    name: string;
    handle?: string;
    avatarUrl?: string | null;
    user?: { id: string };
    _count?: { followers: number };
  } | null;
  show?: { id: string; title: string; coverUrl?: string | null } | null;
  likes?: { userId: string; type: string }[];
  upNext?: UpNextVideo[];
  isSubscribed?: boolean;
  userLike?: 'like' | 'dislike' | null;
  isFollowingShow?: boolean;
  showFollowerCount?: number;
  linkedClip?: LinkedMedia | null;
  linkedEpisode?: LinkedEpisode | null;
  paywallInfo?: PaywallInfo | null;
}
interface UpNextVideo {
  id: string;
  title: string;
  thumbnailUrl?: string | null;
  duration?: number | null;
  views?: number;
  channel?: { name: string; handle?: string };
}
interface LinkedMedia {
  id: string;
  title: string;
  thumbnailUrl?: string | null;
  duration?: number | null;
}
interface LinkedEpisode {
  id: string;
  title: string;
  thumbnailUrl?: string | null;
  duration?: number | null;
  season: { seasonNumber: number; show: { id: string; title: string } };
}
interface PaywallInfo {
  productId: string;
  productName: string;
  entitlementType: 'PPV' | 'SVOD';
  price?: number;
  currency?: string;
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

// ─── Main screen ──────────────────────────────────────────────────────────────

export default function VideoWatchScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router  = useRouter();

  // ── Data state ──
  const [video,    setVideo]    = useState<VideoDetail | null>(null);
  const [loading,  setLoading]  = useState(true);
  const [resumeAt, setResumeAt] = useState(0);

  // ── Like/dislike ──
  const [userLike,   setUserLike]   = useState<'like' | 'dislike' | null>(null);
  const [likeCount,  setLikeCount]  = useState(0);
  const [disCount,   setDisCount]   = useState(0);

  // ── Subscribe / show follow ──
  const [subscribed,    setSubscribed]    = useState(false);
  const [subCount,      setSubCount]      = useState(0);
  const [showFollowing, setShowFollowing] = useState(false);
  const [showFollowerCnt, setShowFollowerCnt] = useState(0);

  // ── Moment-likes ──
  const [likedSeconds,  setLikedSeconds]  = useState<number[]>([]);

  // ── Comments ──
  const [comments,      setComments]      = useState<Comment[]>([]);
  const [commentInput,  setCommentInput]  = useState('');
  const [commentCount,  setCommentCount]  = useState(0);
  const [replyTo,       setReplyTo]       = useState<Comment | null>(null);
  const [showAllComments, setShowAllComments] = useState(false);

  // ── UI ──
  const [showDesc,   setShowDesc]   = useState(false);
  const [autoNext,   setAutoNext]   = useState(true);
  const [countdown,  setCountdown]  = useState(0);

  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // ── Load video + progress in parallel ──
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    Promise.allSettled([
      apiGet<VideoDetail>(`/api/videos/${id}`),
      apiGet<{ seconds?: number } | null>(`/api/progress?videoId=${id}`),
      apiGet<{ buckets?: number[]; userLikedSeconds?: number[] }>(`/api/videos/${id}/moment-likes`),
    ]).then(([vRes, progRes, mlRes]) => {
      if (cancelled) return;

      if (vRes.status === 'fulfilled') {
        const v = vRes.value;
        setVideo(v);
        setUserLike(v.userLike ?? null);
        setLikeCount(v.likes?.filter(l => l.type === 'like').length ?? 0);
        setDisCount(v.likes?.filter(l => l.type === 'dislike').length ?? 0);
        setSubscribed(v.isSubscribed ?? false);
        setSubCount(v.channel?._count?.followers ?? 0);
        setShowFollowing(v.isFollowingShow ?? false);
        setShowFollowerCnt(v.showFollowerCount ?? 0);

        // Fetch comments separately
        apiGet<Comment[]>(`/api/videos/${id}/comments`)
          .then(c => { if (!cancelled) { setComments(c); setCommentCount(c.length); } })
          .catch(() => {});
      }

      if (progRes.status === 'fulfilled' && progRes.value?.seconds && progRes.value.seconds > 10) {
        setResumeAt(progRes.value.seconds);
      }
      if (mlRes.status === 'fulfilled') {
        if (Array.isArray(mlRes.value?.userLikedSeconds)) setLikedSeconds(mlRes.value.userLikedSeconds!);
      }

      setLoading(false);
    });
    return () => { cancelled = true; };
  }, [id]);

  // Cleanup countdown on unmount
  useEffect(() => () => { if (timerRef.current) clearInterval(timerRef.current); }, []);

  // ── Progress tracking ──
  const handleTimeUpdate = useCallback((current: number, duration: number) => {
    if (duration <= 0) return;
    const percent = current / duration;
    apiPost('/api/progress', {
      videoId: id,
      seconds: Math.floor(current),
      percent,
    }).catch(() => {});
  }, [id]);

  // ── Ended → autoplay countdown ──
  const handleEnded = useCallback(() => {
    const next = video?.upNext?.[0];
    if (!autoNext || !next) return;
    let secs = 5;
    setCountdown(secs);
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = setInterval(() => {
      secs -= 1;
      setCountdown(secs);
      if (secs <= 0) {
        clearInterval(timerRef.current!);
        timerRef.current = null;
        router.push(`/(app)/watch/${next.id}` as never);
      }
    }, 1000);
  }, [autoNext, video, router]);

  // ── Like moment ──
  const handleLikeMoment = useCallback(async (timestampSec: number) => {
    const res = await apiPost<{ liked?: boolean }>(`/api/videos/${id}/moment-likes`, { timestampSec });
    setLikedSeconds(prev =>
      res.liked ? [...prev, timestampSec] : prev.filter(s => s !== timestampSec)
    );
  }, [id]);

  // ── Like / dislike ──
  async function toggleLike(type: 'like' | 'dislike') {
    const sending = userLike === type ? 'remove' : type;
    const res = await apiPost<{ likes: number; dislikes: number; userLike: 'like' | 'dislike' | null }>(
      `/api/videos/${id}/like`, { type: sending }
    );
    setLikeCount(res.likes);
    setDisCount(res.dislikes);
    setUserLike(res.userLike ?? null);
  }

  // ── Subscribe / show follow ──
  async function toggleSubscribe() {
    const channelId = video?.channel?.id;
    if (!channelId) return;
    const res = await apiPost<{ subscribed: boolean; count: number }>(
      `/api/channels/${channelId}/subscribe`
    );
    setSubscribed(res.subscribed);
    setSubCount(res.count);
  }

  async function toggleShowFollow() {
    const showId = video?.show?.id;
    if (!showId) return;
    const res = await apiPost<{ subscribed: boolean; count: number }>(
      `/api/shows/${showId}/subscribe`
    );
    setShowFollowing(res.subscribed);
    setShowFollowerCnt(res.count);
  }

  const isChannelOwned = !!video?.channel;
  function toggleSourceFollow() {
    if (isChannelOwned) toggleSubscribe();
    else toggleShowFollow();
  }
  const sourceFollowed      = isChannelOwned ? subscribed : showFollowing;
  const sourceFollowerCount = isChannelOwned ? subCount   : showFollowerCnt;
  const sourceName          = isChannelOwned ? video?.channel?.name : video?.show?.title;

  // ── Share ──
  async function handleShare() {
    try {
      await Share.share({
        title: video?.title ?? 'Watch on WeStreem',
        url: `https://www.westreem.com/watch/${id}`,
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
    const c = await apiPost<Comment>(`/api/videos/${id}/comments`, body);
    if (replyTo) {
      setComments(prev => prev.map(cm =>
        cm.id === replyTo.id
          ? { ...cm, replies: [...(cm.replies ?? []), c] }
          : cm
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

  // ── Paywall ──
  const paywallInfo = video?.paywallInfo ?? null;
  const isProcessing = !!(video?.cfStreamId && !video.videoUrl);

  // ─────────────────────────────────────────────────────────────────────────────

  if (loading) {
    return (
      <Screen style={S.center}>
        <ActivityIndicator color={C.watch} size="large" />
      </Screen>
    );
  }
  if (!video) {
    return (
      <Screen style={S.center}>
        <Text style={{ color: C.textSub, marginBottom: 16 }}>Video not found</Text>
        <TouchableOpacity onPress={() => router.back()} style={S.backBtnFull}>
          <Text style={{ color: C.watch, fontWeight: '600' }}>← Go back</Text>
        </TouchableOpacity>
      </Screen>
    );
  }

  const upNext        = video.upNext ?? [];
  const desc          = video.description;
  const showingUpNext = upNext.slice(0, showAllComments ? upNext.length : 5);
  const visibleCmts   = comments.slice(0, showAllComments ? comments.length : 3);

  return (
    <Screen>
      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        keyboardVerticalOffset={0}
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

            {video.videoUrl ? (
              <VideoPlayer
                src={video.videoUrl}
                poster={video.thumbnailUrl ?? undefined}
                autoPlay
                initialTime={resumeAt}
                onTimeUpdate={handleTimeUpdate}
                onEnded={handleEnded}
                onLikeMoment={handleLikeMoment}
                onNext={upNext.length > 0 ? () => router.push(`/(app)/watch/${upNext[0].id}` as never) : undefined}
                userLikedSeconds={likedSeconds}
              />
            ) : (
              <View style={[S.playerWrap, { aspectRatio: 16 / 9, backgroundColor: '#000', justifyContent: 'center', alignItems: 'center' }]}>
                <Text style={{ color: C.textSub, fontSize: 13 }}>
                  {isProcessing ? 'Processing…' : 'No video available'}
                </Text>
              </View>
            )}

            {/* Autoplay countdown overlay */}
            {countdown > 0 && upNext[0] && (
              <AutoplayOverlay
                countdown={countdown}
                nextTitle={upNext[0].title}
                onPlayNow={() => { clearInterval(timerRef.current!); setCountdown(0); router.push(`/(app)/watch/${upNext[0].id}` as never); }}
                onCancel={() => { clearInterval(timerRef.current!); setCountdown(0); }}
              />
            )}

            {/* Paywall gate */}
            {paywallInfo && <PaywallOverlay info={paywallInfo} onBack={() => router.back()} />}
          </View>

          <View style={S.body}>
            {/* Breadcrumb (show-linked) */}
            {video.show && (
              <View style={S.breadcrumb}>
                <Text style={S.breadcrumbTxt}>Home</Text>
                <Text style={S.breadcrumbSep}>/</Text>
                <Text style={S.breadcrumbTxt}>{video.show.title}</Text>
                <Text style={S.breadcrumbSep}>/</Text>
                <Text style={[S.breadcrumbTxt, { color: 'rgba(255,255,255,0.55)' }]}>{video.title}</Text>
              </View>
            )}

            {/* Title */}
            <Text style={S.title}>{video.title}</Text>

            {/* Metadata pills */}
            <View style={S.metaRow}>
              {(video.views ?? 0) > 0 && (
                <Text style={S.metaChip}>{fmtCount(video.views!)} views</Text>
              )}
              {video.createdAt && (
                <Text style={S.metaChip}>{timeAgo(video.createdAt)}</Text>
              )}
            </View>

            {/* Description */}
            {desc && (
              <TouchableOpacity
                style={S.descBox}
                activeOpacity={0.8}
                onPress={() => setShowDesc(s => !s)}
              >
                <Text
                  style={S.descTxt}
                  numberOfLines={showDesc ? undefined : 2}
                >
                  {desc}
                </Text>
                {desc.length > 120 && (
                  <Text style={[S.descMore, { color: C.watch }]}>
                    {showDesc ? 'Show less' : '...more'}
                  </Text>
                )}
              </TouchableOpacity>
            )}

            {/* Source row + action buttons */}
            <View style={S.sourceSection}>
              {/* Avatar + name + follower count */}
              <View style={S.sourceLeft}>
                <View style={isChannelOwned ? S.avatar : S.avatarSquare}>
                  {video.channel?.avatarUrl ? (
                    <Image source={{ uri: video.channel.avatarUrl }} style={StyleSheet.absoluteFill} />
                  ) : (
                    <Text style={S.avatarInitial}>{sourceName?.[0]?.toUpperCase() ?? '?'}</Text>
                  )}
                </View>
                <View style={{ flex: 1, minWidth: 0 }}>
                  <Text style={S.sourceName} numberOfLines={1}>{sourceName}</Text>
                  {sourceFollowerCount > 0 && (
                    <Text style={S.sourceFollowers}>
                      {fmtCount(sourceFollowerCount)} follower{sourceFollowerCount !== 1 ? 's' : ''}
                    </Text>
                  )}
                </View>
                <TouchableOpacity
                  onPress={toggleSourceFollow}
                  style={[S.followBtn, sourceFollowed && S.followBtnActive]}
                >
                  <Text style={[S.followTxt, sourceFollowed && { color: 'rgba(255,255,255,0.7)' }]}>
                    {sourceFollowed ? 'Following' : 'Follow'}
                  </Text>
                </TouchableOpacity>
              </View>

              {/* Action buttons row */}
              <View style={S.actions}>
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
                  <Text style={[S.actionIcon, userLike === 'dislike' && { color: 'rgba(255,255,255,0.85)' }]}>
                    👎
                  </Text>
                </TouchableOpacity>

                {/* Share */}
                <TouchableOpacity onPress={handleShare} style={S.actionBtn}>
                  <Text style={S.actionIcon}>↗</Text>
                  <Text style={S.actionTxt}>Share</Text>
                </TouchableOpacity>
              </View>
            </View>

            {/* Linked clip */}
            {video.linkedClip && (
              <LinkedMediaCard
                type="clip"
                item={video.linkedClip}
                onPress={() => router.push(`/(app)/watch/${video.linkedClip!.id}` as never)}
              />
            )}

            {/* Linked episode */}
            {video.linkedEpisode && (
              <LinkedMediaCard
                type="episode"
                item={video.linkedEpisode}
                subtitle={`${video.linkedEpisode.season.show.title} · S${video.linkedEpisode.season.seasonNumber}`}
                onPress={() => router.push(`/(app)/watch/episode/${video.linkedEpisode!.id}` as never)}
              />
            )}

            {/* ── Up Next ── */}
            {upNext.length > 0 && (
              <View style={S.section}>
                <View style={S.sectionHeader}>
                  <Text style={S.sectionTitle}>Up Next</Text>
                  {/* Autoplay toggle */}
                  <TouchableOpacity
                    onPress={() => setAutoNext(v => !v)}
                    style={[S.toggle, autoNext && S.toggleOn]}
                    activeOpacity={0.8}
                  >
                    <Animated.View style={[S.toggleKnob, autoNext && S.toggleKnobOn]} />
                  </TouchableOpacity>
                </View>

                {upNext.map((v, i) => (
                  <TouchableOpacity
                    key={v.id}
                    onPress={() => router.push(`/(app)/watch/${v.id}` as never)}
                    style={S.upNextRow}
                    activeOpacity={0.75}
                  >
                    <View style={S.upNextThumb}>
                      {v.thumbnailUrl && (
                        <Image source={{ uri: v.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
                      )}
                      {fmtDuration(v.duration) && (
                        <View style={S.durationBadge}>
                          <Text style={S.durationTxt}>{fmtDuration(v.duration)}</Text>
                        </View>
                      )}
                      {i === 0 && countdown > 0 && (
                        <View style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.6)', alignItems: 'center', justifyContent: 'center' }]}>
                          <Text style={{ color: '#fff', fontWeight: '800', fontSize: 20 }}>{countdown}</Text>
                        </View>
                      )}
                    </View>
                    <View style={{ flex: 1 }}>
                      {i === 0 && countdown > 0 && (
                        <Text style={[S.upNextLabel, { color: C.watch }]}>Up next</Text>
                      )}
                      <Text style={S.upNextTitle} numberOfLines={2}>{v.title}</Text>
                      {v.channel?.name && (
                        <Text style={S.upNextChannel}>{v.channel.name}</Text>
                      )}
                      {(v.views ?? 0) > 0 && (
                        <Text style={S.upNextViews}>{fmtCount(v.views!)} views</Text>
                      )}
                    </View>
                  </TouchableOpacity>
                ))}
              </View>
            )}

            {/* ── Comments ── */}
            <View style={S.section}>
              <Text style={S.sectionTitle}>{commentCount} Comment{commentCount !== 1 ? 's' : ''}</Text>

              {/* Comment input */}
              <View style={S.commentInput}>
                <TextInput
                  style={S.commentTextInput}
                  placeholder={replyTo ? `Reply to ${replyTo.user?.name ?? 'comment'}…` : 'Add a comment…'}
                  placeholderTextColor={C.textMuted}
                  value={commentInput}
                  onChangeText={setCommentInput}
                  multiline
                  returnKeyType="send"
                />
                <View style={S.commentActions}>
                  {replyTo && (
                    <TouchableOpacity onPress={() => setReplyTo(null)} style={S.commentCancelReply}>
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
                <TouchableOpacity
                  onPress={() => setShowAllComments(v => !v)}
                  style={S.showMoreBtn}
                >
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
      <TouchableOpacity onPress={onBack} style={Pw.backBtn}>
        <Text style={{ color: 'rgba(255,255,255,0.5)', fontSize: 13 }}>← Go back</Text>
      </TouchableOpacity>
    </View>
  );
}

function LinkedMediaCard({
  type, item, subtitle, onPress,
}: {
  type: 'clip' | 'episode';
  item: { id: string; title: string; thumbnailUrl?: string | null; duration?: number | null };
  subtitle?: string;
  onPress: () => void;
}) {
  const dur = fmtDuration(item.duration);
  return (
    <TouchableOpacity onPress={onPress} style={Lk.container} activeOpacity={0.8}>
      <View style={Lk.thumb}>
        {item.thumbnailUrl
          ? <Image source={{ uri: item.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          : <Text style={{ color: 'rgba(255,255,255,0.2)', fontSize: 18 }}>{type === 'episode' ? '📺' : '▶'}</Text>}
        {dur && (
          <View style={Lk.durBadge}><Text style={Lk.durTxt}>{dur}</Text></View>
        )}
      </View>
      <View style={{ flex: 1 }}>
        <Text style={Lk.label}>{type === 'clip' ? 'Watch full clip' : 'Watch episode'}</Text>
        <Text style={Lk.title} numberOfLines={1}>{item.title}</Text>
        {subtitle && <Text style={Lk.sub}>{subtitle}</Text>}
      </View>
      <Text style={{ color: 'rgba(255,255,255,0.2)', fontSize: 14 }}>›</Text>
    </TouchableOpacity>
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
          ? <Image source={{ uri: comment.user.image }} style={StyleSheet.absoluteFill} borderRadius={14} />
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
        {/* Replies */}
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
  center:        { flex: 1, alignItems: 'center', justifyContent: 'center' },
  backBtnFull:   { paddingHorizontal: 20, paddingVertical: 10, borderRadius: 20, borderWidth: 1, borderColor: C.border },
  scrollContent: { paddingBottom: 80 },
  playerWrap:    { width: '100%', backgroundColor: '#000', position: 'relative' },
  transcoding: {
    position: 'absolute', top: 12, left: 0, right: 0, zIndex: 20,
    alignItems: 'center',
  },
  transcodingTxt: {
    backgroundColor: 'rgba(251,191,36,0.15)', color: '#fbbf24',
    fontSize: 11, fontWeight: '600', paddingHorizontal: 12, paddingVertical: 5,
    borderRadius: 20, borderWidth: 1, borderColor: 'rgba(251,191,36,0.3)',
  },
  body: { paddingHorizontal: 16, paddingTop: 12 },

  breadcrumb:    { flexDirection: 'row', alignItems: 'center', flexWrap: 'wrap', marginBottom: 8, gap: 4 },
  breadcrumbTxt: { fontSize: 11, color: 'rgba(255,255,255,0.35)' },
  breadcrumbSep: { fontSize: 11, color: 'rgba(255,255,255,0.2)' },

  title:         { fontSize: 19, fontWeight: '800', color: C.text, lineHeight: 26, marginBottom: 6 },

  metaRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 10 },
  metaChip: { fontSize: 12, color: C.textSub },

  descBox: { backgroundColor: C.surface2, borderRadius: 10, padding: 12, marginBottom: 14 },
  descTxt: { color: C.textSub, fontSize: 13, lineHeight: 19 },
  descMore:{ fontSize: 12, fontWeight: '600', marginTop: 4 },

  sourceSection: { marginBottom: 14 },
  sourceLeft: {
    flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 12,
  },
  avatar: {
    width: 40, height: 40, borderRadius: 20, backgroundColor: C.surface2,
    overflow: 'hidden', alignItems: 'center', justifyContent: 'center',
  },
  avatarSquare: {
    width: 40, height: 40, borderRadius: 8, backgroundColor: C.surface2,
    overflow: 'hidden', alignItems: 'center', justifyContent: 'center',
  },
  avatarInitial: { color: C.watch, fontWeight: '700', fontSize: 16 },
  sourceName: { fontSize: 14, fontWeight: '600', color: C.text, flex: 1 },
  sourceFollowers: { fontSize: 11, color: C.textMuted, marginTop: 1 },
  followBtn: {
    paddingHorizontal: 14, paddingVertical: 7, borderRadius: 20,
    backgroundColor: C.watch,
  },
  followBtnActive: { backgroundColor: C.surface2, borderWidth: 1, borderColor: C.border },
  followTxt: { fontSize: 13, fontWeight: '600', color: '#0a0a0f' },

  actions: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  actionBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    paddingHorizontal: 14, paddingVertical: 8,
    borderRadius: 20, backgroundColor: C.surface,
    borderWidth: 1, borderColor: C.border,
  },
  actionBtnActive: { backgroundColor: C.surface2, borderColor: C.border2 },
  actionIcon: { fontSize: 15, color: C.textSub },
  actionTxt:  { fontSize: 12, color: C.textSub, fontWeight: '500' },

  section:       { marginTop: 20 },
  sectionHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 },
  sectionTitle:  { fontSize: 15, fontWeight: '700', color: C.text },

  toggle: {
    width: 36, height: 20, borderRadius: 10, backgroundColor: 'rgba(255,255,255,0.12)',
    justifyContent: 'center', paddingHorizontal: 2,
  },
  toggleOn: { backgroundColor: C.watch },
  toggleKnob: {
    width: 16, height: 16, borderRadius: 8, backgroundColor: '#fff',
    alignSelf: 'flex-start',
  },
  toggleKnobOn: { alignSelf: 'flex-end' },

  upNextRow: { flexDirection: 'row', gap: 10, marginBottom: 12 },
  upNextThumb: {
    width: 128, aspectRatio: 16 / 9, borderRadius: 8,
    backgroundColor: C.surface2, overflow: 'hidden', position: 'relative',
  },
  durationBadge: {
    position: 'absolute', bottom: 4, right: 4,
    backgroundColor: 'rgba(0,0,0,0.8)', borderRadius: 4,
    paddingHorizontal: 5, paddingVertical: 2,
  },
  durationTxt: { color: '#fff', fontSize: 10, fontWeight: '600' },
  upNextLabel:  { fontSize: 10, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 2 },
  upNextTitle:  { fontSize: 13, fontWeight: '600', color: C.text, lineHeight: 18 },
  upNextChannel: { fontSize: 11, color: C.textMuted, marginTop: 2 },
  upNextViews:   { fontSize: 11, color: 'rgba(255,255,255,0.25)', marginTop: 1 },

  commentInput: {
    backgroundColor: C.surface, borderRadius: 10,
    borderWidth: 1, borderColor: C.border,
    marginBottom: 14, padding: 10,
  },
  commentTextInput: {
    color: C.text, fontSize: 13, minHeight: 36, maxHeight: 80,
  },
  commentActions: { flexDirection: 'row', justifyContent: 'flex-end', marginTop: 6, gap: 8 },
  commentCancelReply: { paddingHorizontal: 10, paddingVertical: 5 },
  postBtn: {
    backgroundColor: C.watch, borderRadius: 16,
    paddingHorizontal: 14, paddingVertical: 6,
  },
  postBtnTxt: { color: '#0a0a0f', fontSize: 12, fontWeight: '700' },

  showMoreBtn: {
    alignItems: 'center', paddingVertical: 10,
    borderTopWidth: 1, borderTopColor: C.border, marginTop: 6,
  },
});

// Autoplay overlay styles
const Ov = StyleSheet.create({
  container: {
    ...StyleSheet.absoluteFillObject, backgroundColor: 'rgba(0,0,0,0.82)',
    alignItems: 'center', justifyContent: 'center', zIndex: 20, gap: 10, padding: 24,
  },
  hint:      { color: 'rgba(255,255,255,0.5)', fontSize: 13 },
  num:       { color: '#fff', fontWeight: '800', fontSize: 26 },
  nextTitle: { color: '#fff', fontWeight: '600', fontSize: 14, textAlign: 'center', maxWidth: 260 },
  btnRow:    { flexDirection: 'row', gap: 10, marginTop: 6 },
  playBtn:   { paddingHorizontal: 20, paddingVertical: 10, borderRadius: 24, backgroundColor: C.watch },
  playTxt:   { color: '#0a0a0f', fontWeight: '700', fontSize: 14 },
  cancelBtn: { paddingHorizontal: 20, paddingVertical: 10, borderRadius: 24, backgroundColor: 'rgba(255,255,255,0.10)' },
  cancelTxt: { color: '#fff', fontSize: 14 },
});

// Paywall overlay styles
const Pw = StyleSheet.create({
  container: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(0,0,0,0.92)',
    alignItems: 'center', justifyContent: 'center',
    zIndex: 30, gap: 10, padding: 24,
  },
  iconWrap: {
    width: 56, height: 56, borderRadius: 28,
    backgroundColor: `${C.watch}22`,
    alignItems: 'center', justifyContent: 'center',
  },
  label: { color: C.watch, fontSize: 11, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 1.5 },
  name:  { color: C.text, fontSize: 20, fontWeight: '800', textAlign: 'center' },
  price: { color: C.textSub, fontSize: 13 },
  backBtn: { marginTop: 10, paddingVertical: 6 },
});

// Linked card styles
const Lk = StyleSheet.create({
  container: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: C.surface, borderRadius: 10,
    borderWidth: 1, borderColor: C.border,
    padding: 10, marginBottom: 10, marginTop: 4,
  },
  thumb: {
    width: 72, aspectRatio: 16 / 9, borderRadius: 8,
    backgroundColor: C.surface2, overflow: 'hidden',
    alignItems: 'center', justifyContent: 'center', position: 'relative',
  },
  durBadge: {
    position: 'absolute', bottom: 3, right: 3,
    backgroundColor: 'rgba(0,0,0,0.8)', borderRadius: 3,
    paddingHorizontal: 4, paddingVertical: 1,
  },
  durTxt:  { color: '#fff', fontSize: 9, fontWeight: '600' },
  label:   { color: C.watch, fontSize: 10, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 2 },
  title:   { color: C.text, fontSize: 13, fontWeight: '600' },
  sub:     { color: C.textMuted, fontSize: 11, marginTop: 2 },
});

// Comment styles
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
