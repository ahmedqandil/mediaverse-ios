/**
 * Home / browse feed.
 */
import { useEffect, useState } from 'react';
import {
  ScrollView, View, Text, ActivityIndicator,
  StyleSheet, RefreshControl,
} from 'react-native';
import { useRouter } from 'expo-router';
import { Screen } from '@/components/ui/Screen';
import { ContentCard } from '@/components/ContentCard';
import { apiGet } from '@/lib/api';
import { C } from '@/lib/constants';
import type { VideoItem } from '@/lib/types';

interface FeedSection { label: string; items: VideoItem[] }

export default function HomeScreen() {
  const [sections,    setSections]   = useState<FeedSection[]>([]);
  const [loading,     setLoading]    = useState(true);
  const [refreshing,  setRefreshing] = useState(false);
  const router = useRouter();

  async function load() {
    try {
      // Reuse the existing home-feed API
      const data = await apiGet<{ sections: FeedSection[] }>('/api/feed');
      setSections(data.sections ?? []);
    } catch {
      // fallback: empty
    } finally {
      setLoading(false); setRefreshing(false);
    }
  }

  useEffect(() => { load(); }, []);

  if (loading) {
    return (
      <Screen style={styles.center}>
        <ActivityIndicator color={C.watch} size="large" />
      </Screen>
    );
  }

  return (
    <Screen>
      <ScrollView
        contentContainerStyle={styles.scroll}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={() => { setRefreshing(true); load(); }}
            tintColor={C.watch}
          />
        }
      >
        {/* Header */}
        <View style={styles.header}>
          <Text style={styles.logo}>Mediaverse</Text>
        </View>

        {sections.length === 0 && (
          <View style={styles.empty}>
            <Text style={styles.emptyTxt}>Nothing here yet.</Text>
          </View>
        )}

        {sections.map(sec => (
          <View key={sec.label} style={styles.section}>
            <Text style={styles.sectionLabel}>{sec.label}</Text>
            <ScrollView
              horizontal
              showsHorizontalScrollIndicator={false}
              contentContainerStyle={styles.row}
            >
              {sec.items.map(item => (
                <ContentCard
                  key={item.id}
                  item={item}
                  onPress={() => router.push(`/(app)/watch/${item.id}`)}
                />
              ))}
            </ScrollView>
          </View>
        ))}
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  center:       { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll:       { paddingBottom: 40 },
  header:       { paddingHorizontal: 20, paddingTop: 16, paddingBottom: 8 },
  logo:         { fontSize: 22, fontWeight: '800', color: C.text },
  section:      { marginTop: 24 },
  sectionLabel: { fontSize: 15, fontWeight: '700', color: C.text, paddingHorizontal: 20, marginBottom: 12 },
  row:          { paddingHorizontal: 20 },
  empty:        { alignItems: 'center', paddingTop: 80 },
  emptyTxt:     { color: C.textMuted, fontSize: 14 },
});
