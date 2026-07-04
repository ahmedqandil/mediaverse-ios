import { useEffect, useState } from 'react';
import {
  ScrollView, View, Text, TouchableOpacity,
  ActivityIndicator, StyleSheet,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { VideoPlayer } from '@/components/VideoPlayer';
import { Screen } from '@/components/ui/Screen';
import { apiGet, apiPost } from '@/lib/api';
import { C } from '@/lib/constants';
import type { VideoItem } from '@/lib/types';

interface VideoDetail extends VideoItem {
  description?: string;
  viewCount?:   number;
  likeCount?:   number;
  userLikedSeconds?: number[];
  heatmapData?:      number[];
}

export default function WatchScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router  = useRouter();
  const [video, setVideo] = useState<VideoDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [liked, setLiked] = useState(false);
  const [likeCount, setLikeCount] = useState(0);

  useEffect(() => {
    apiGet<VideoDetail>(`/api/videos/${id}`)
      .then(v => { setVideo(v); setLikeCount(v.likeCount ?? 0); })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [id]);

  async function likeMoment(sec: number) {
    await apiPost(`/api/videos/${id}/moment-likes`, { timestampSec: sec });
  }

  async function toggleLike() {
    const next = !liked;
    setLiked(next);
    setLikeCount(c => next ? c + 1 : c - 1);
    await apiPost(`/api/videos/${id}/like`, { liked: next });
  }

  if (loading) {
    return (
      <Screen style={styles.center}>
        <ActivityIndicator color={C.watch} />
      </Screen>
    );
  }
  if (!video) {
    return (
      <Screen style={styles.center}>
        <Text style={{ color: C.textSub }}>Video not found</Text>
      </Screen>
    );
  }

  return (
    <Screen>
      {/* Back */}
      <TouchableOpacity onPress={() => router.back()} style={styles.backBtn}>
        <Text style={styles.backTxt}>← Back</Text>
      </TouchableOpacity>

      <ScrollView contentContainerStyle={styles.scroll}>
        {/* Player */}
        {video.videoUrl && (
          <VideoPlayer
            src={video.videoUrl}
            onLikeMoment={likeMoment}
            userLikedSeconds={video.userLikedSeconds}
          />
        )}

        {/* Title + channel */}
        <View style={styles.meta}>
          <Text style={styles.title}>{video.title}</Text>

          {video.channel && (
            <View style={styles.channelRow}>
              <Text style={styles.channel}>{video.channel.name}</Text>
            </View>
          )}

          {/* Actions */}
          <View style={styles.actions}>
            <TouchableOpacity onPress={toggleLike} style={styles.actionBtn}>
              <Text style={[styles.actionIcon, liked && { color: C.watch }]}>
                {liked ? '♥' : '♡'}
              </Text>
              <Text style={[styles.actionTxt, liked && { color: C.watch }]}>
                {likeCount}
              </Text>
            </TouchableOpacity>
            <View style={[styles.actionBtn, { opacity: 0.4 }]}>
              <Text style={styles.actionIcon}>💬</Text>
              <Text style={styles.actionTxt}>Comments</Text>
            </View>
            <View style={[styles.actionBtn, { opacity: 0.4 }]}>
              <Text style={styles.actionIcon}>↗</Text>
              <Text style={styles.actionTxt}>Share</Text>
            </View>
          </View>

          {/* Description */}
          {video.description ? (
            <View style={styles.desc}>
              <Text style={styles.descTxt}>{video.description}</Text>
            </View>
          ) : null}
        </View>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  center:   { flex: 1, alignItems: 'center', justifyContent: 'center' },
  backBtn:  { padding: 16, paddingBottom: 0 },
  backTxt:  { color: C.textSub, fontSize: 14 },
  scroll:   { paddingBottom: 60 },
  meta:     { padding: 16, gap: 10 },
  title:    { fontSize: 18, fontWeight: '800', color: C.text },
  channelRow: { flexDirection: 'row', alignItems: 'center' },
  channel:  { fontSize: 13, color: C.textSub },
  actions:  { flexDirection: 'row', gap: 20, paddingVertical: 4 },
  actionBtn:{ flexDirection: 'row', alignItems: 'center', gap: 6 },
  actionIcon:{ fontSize: 18, color: C.textSub },
  actionTxt: { fontSize: 12, color: C.textSub },
  desc:     {
    backgroundColor: C.surface2,
    borderRadius: 10, padding: 12,
  },
  descTxt:  { color: C.textSub, fontSize: 13, lineHeight: 19 },
});
