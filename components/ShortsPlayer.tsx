/**
 * Vertical paging shorts / microdrama player.
 * Full-screen cards, auto-plays active, pauses neighbours.
 */
import { useRef, useState, useCallback } from 'react';
import {
  Dimensions, FlatList, View, Text, TouchableOpacity,
  StyleSheet, type ListRenderItemInfo,
} from 'react-native';
import { VideoView, useVideoPlayer } from 'expo-video';
import { C } from '@/lib/constants';
import type { EpisodeItem } from '@/lib/types';

const { height: SH, width: SW } = Dimensions.get('window');

interface Props {
  episodes:  EpisodeItem[];
  onLike?:   (id: string) => void;
  onComment?:(id: string) => void;
  onShare?:  (id: string) => void;
}

function EpisodeCard({
  episode, active,
}: { episode: EpisodeItem; active: boolean }) {
  const [paused, setPaused] = useState(false);
  const [progress, setProgress] = useState(0);

  const player = useVideoPlayer(
    active && episode.videoUrl ? episode.videoUrl : null,
    p => { if (active) p.play(); else p.pause(); },
  );

  return (
    <View style={styles.card}>
      {/* Video */}
      {active && episode.videoUrl ? (
        <VideoView
          player={player}
          style={StyleSheet.absoluteFill}
          contentFit="cover"
          nativeControls={false}
        />
      ) : (
        <View style={[StyleSheet.absoluteFill, { backgroundColor: C.surface }]} />
      )}

      {/* Tap to pause */}
      <TouchableOpacity
        style={StyleSheet.absoluteFill}
        activeOpacity={1}
        onPress={() => {
          if (paused) { player.play(); setPaused(false); }
          else        { player.pause(); setPaused(true); }
        }}
      />

      {/* Bottom info */}
      <View style={styles.info}>
        <Text style={styles.title} numberOfLines={2}>{episode.title}</Text>
        <Text style={styles.ep}>Episode {episode.episodeNumber}</Text>
        {/* Progress bar */}
        <View style={styles.progTrack}>
          <View style={[styles.progFill, { width: `${progress * 100}%` }]} />
        </View>
      </View>

      {/* Right action buttons */}
      <View style={styles.actions}>
        <ActionBtn icon="♥" label="Like"     onPress={() => {}} />
        <ActionBtn icon="💬" label="Comment" onPress={() => {}} />
        <ActionBtn icon="↗" label="Share"    onPress={() => {}} />
      </View>
    </View>
  );
}

function ActionBtn({
  icon, label, onPress,
}: { icon: string; label: string; onPress: () => void }) {
  return (
    <TouchableOpacity onPress={onPress} style={styles.actionBtn}>
      <Text style={styles.actionIcon}>{icon}</Text>
      <Text style={styles.actionLabel}>{label}</Text>
    </TouchableOpacity>
  );
}

export function ShortsPlayer({ episodes }: Props) {
  const [activeIdx, setActiveIdx] = useState(0);
  const onViewableItemsChanged = useRef(({ viewableItems }: { viewableItems: { index: number | null }[] }) => {
    const i = viewableItems[0]?.index;
    if (i != null) setActiveIdx(i);
  }).current;

  const renderItem = useCallback(
    ({ item, index }: ListRenderItemInfo<EpisodeItem>) => (
      <EpisodeCard episode={item} active={index === activeIdx} />
    ),
    [activeIdx],
  );

  return (
    <FlatList
      data={episodes}
      keyExtractor={e => e.id}
      renderItem={renderItem}
      pagingEnabled
      showsVerticalScrollIndicator={false}
      snapToInterval={SH}
      decelerationRate="fast"
      onViewableItemsChanged={onViewableItemsChanged}
      viewabilityConfig={{ itemVisiblePercentThreshold: 60 }}
      getItemLayout={(_, i) => ({ length: SH, offset: SH * i, index: i })}
      maxToRenderPerBatch={3}
      windowSize={3}
    />
  );
}

const styles = StyleSheet.create({
  card: {
    width: SW, height: SH,
    backgroundColor: '#000', overflow: 'hidden',
  },
  info: {
    position: 'absolute', bottom: 80, left: 16, right: 80,
  },
  title: { color: '#fff', fontSize: 15, fontWeight: '700', marginBottom: 4 },
  ep:    { color: 'rgba(255,255,255,0.5)', fontSize: 12, marginBottom: 10 },
  progTrack: {
    height: 3, borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.18)',
    overflow: 'hidden',
  },
  progFill: { height: '100%', backgroundColor: C.watch },
  actions: {
    position: 'absolute', right: 12, bottom: 100,
    alignItems: 'center', gap: 22,
  },
  actionBtn:   { alignItems: 'center', gap: 4 },
  actionIcon:  { fontSize: 26 },
  actionLabel: { color: 'rgba(255,255,255,0.7)', fontSize: 11 },
});
