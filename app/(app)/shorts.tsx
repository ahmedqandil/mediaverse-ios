import { useEffect, useState } from 'react';
import { ActivityIndicator, View, StyleSheet } from 'react-native';
import { ShortsPlayer } from '@/components/ShortsPlayer';
import { apiGet } from '@/lib/api';
import { C } from '@/lib/constants';
import type { EpisodeItem } from '@/lib/types';

export default function ShortsScreen() {
  const [episodes, setEpisodes] = useState<EpisodeItem[]>([]);
  const [loading,  setLoading]  = useState(true);

  useEffect(() => {
    apiGet<{ episodes: EpisodeItem[] }>('/api/microdramas/feed')
      .then(d => setEpisodes(d.episodes ?? []))
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator color={C.watch} size="large" />
      </View>
    );
  }

  return <ShortsPlayer episodes={episodes} />;
}

const styles = StyleSheet.create({
  center: { flex: 1, backgroundColor: C.bg, alignItems: 'center', justifyContent: 'center' },
});
