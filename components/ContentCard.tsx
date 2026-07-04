import { View, Text, Image, TouchableOpacity, StyleSheet } from 'react-native';
import { C } from '@/lib/constants';
import type { VideoItem } from '@/lib/types';

interface Props {
  item:    VideoItem;
  onPress: () => void;
  wide?:   boolean;
}

export function ContentCard({ item, onPress, wide }: Props) {
  return (
    <TouchableOpacity
      onPress={onPress}
      style={[styles.card, wide && styles.wide]}
      activeOpacity={0.85}
    >
      {/* Thumbnail */}
      <View style={[styles.thumb, wide && styles.thumbWide]}>
        {item.thumbnailUrl ? (
          <Image source={{ uri: item.thumbnailUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />
        ) : (
          <View style={[StyleSheet.absoluteFill, styles.thumbPlaceholder]} />
        )}
        {item.accessState === 'locked' && (
          <View style={styles.lockBadge}>
            <Text style={styles.lockTxt}>🔒</Text>
          </View>
        )}
      </View>

      {/* Meta */}
      <View style={styles.meta}>
        <Text style={styles.title} numberOfLines={2}>{item.title}</Text>
        {item.channel && (
          <Text style={styles.channel} numberOfLines={1}>{item.channel.name}</Text>
        )}
      </View>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  card:  { width: 160, marginRight: 10 },
  wide:  { width: '100%', flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  thumb: {
    width: '100%', aspectRatio: 16/9,
    borderRadius: 10, overflow: 'hidden',
    backgroundColor: C.surface2,
  },
  thumbWide: { width: 120, aspectRatio: 16/9, flexShrink: 0 },
  thumbPlaceholder: { backgroundColor: C.surface2 },
  lockBadge: {
    position: 'absolute', top: 6, right: 6,
    backgroundColor: 'rgba(0,0,0,0.6)',
    borderRadius: 6, padding: 4,
  },
  lockTxt: { fontSize: 11 },
  meta:    { marginTop: 6, flex: 1 },
  title:   { color: C.text, fontSize: 13, fontWeight: '600', lineHeight: 18 },
  channel: { color: C.textSub, fontSize: 11, marginTop: 3 },
});
