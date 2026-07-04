/**
 * Network overview / settings screen.
 * Fetches network details + resolved permissions.
 * Shows quick-stat cards + permission-gated nav.
 */
import { useCallback, useEffect, useState } from 'react';
import {
  ScrollView, View, Text, TouchableOpacity,
  ActivityIndicator, StyleSheet, RefreshControl,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { Screen } from '@/components/ui/Screen';
import { apiGet } from '@/lib/api';
import { C } from '@/lib/constants';

interface Network {
  id:          string;
  name:        string;
  handle?:     string;
  description?: string;
  memberCount?: number;
  channelCount?: number;
}

function hasPerm(perms: string[], p: string) { return perms.includes(p); }

export default function NetworkBackstageIndexScreen() {
  const { id: networkId } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();

  const [network,  setNetwork]  = useState<Network | null>(null);
  const [perms,    setPerms]    = useState<string[]>([]);
  const [loading,  setLoading]  = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    try {
      const [n, p] = await Promise.all([
        apiGet<Network>(`/api/backstage/network/${networkId}`).catch(() => null),
        apiGet<string[]>(`/api/me/network-permissions/${networkId}`).catch(() => []),
      ]);
      if (n) setNetwork(n);
      setPerms(p);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [networkId]);

  useEffect(() => { load(); }, [load]);

  if (loading) {
    return <Screen style={styles.center}><ActivityIndicator color={C.watch} /></Screen>;
  }

  return (
    <Screen>
      <TouchableOpacity onPress={() => router.back()} style={styles.back}>
        <Text style={styles.backTxt}>← Network</Text>
      </TouchableOpacity>

      <ScrollView
        contentContainerStyle={styles.scroll}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); load(); }} tintColor={C.watch} />
        }
      >
        {/* Header */}
        <View style={styles.header}>
          <View style={styles.networkIcon}>
            <Text style={{ color: C.watch, fontWeight: '800', fontSize: 20 }}>
              {network?.name?.charAt(0).toUpperCase() ?? 'N'}
            </Text>
          </View>
          <View>
            <Text style={styles.networkName}>{network?.name ?? 'Network'}</Text>
            {network?.handle && <Text style={styles.networkHandle}>@{network.handle}</Text>}
          </View>
        </View>

        {/* Quick stats */}
        <View style={styles.statsRow}>
          {network?.memberCount !== undefined && (
            <View style={styles.statCard}>
              <Text style={styles.statVal}>{network.memberCount}</Text>
              <Text style={styles.statLabel}>Members</Text>
            </View>
          )}
          {network?.channelCount !== undefined && (
            <View style={styles.statCard}>
              <Text style={styles.statVal}>{network.channelCount}</Text>
              <Text style={styles.statLabel}>Channels</Text>
            </View>
          )}
        </View>

        {/* Permission-gated quick-nav links */}
        <Text style={styles.sectionLabel}>Manage</Text>

        {hasPerm(perms, 'manage_members') && (
          <NavItem
            icon="👥"
            label="Members"
            sub="Invite and manage team roles"
            onPress={() => router.push(`/(app)/backstage/network/${networkId}/members`)}
          />
        )}
        {hasPerm(perms, 'view_analytics') && (
          <NavItem
            icon="📊"
            label="Revenue"
            sub="Billing summary and product breakdown"
            onPress={() => router.push(`/(app)/backstage/network/${networkId}/revenue`)}
          />
        )}
        {hasPerm(perms, 'manage_channels') && (
          <NavItem icon="📡" label="Channels"      sub="Manage broadcast channels" onPress={() => {}} />
        )}
        {hasPerm(perms, 'manage_shows') && (
          <NavItem icon="🎬" label="Shows"         sub="Series and episodes" onPress={() => {}} />
        )}
        {hasPerm(perms, 'view_schedule') && (
          <NavItem icon="📅" label="Schedule"      sub="Programming grid" onPress={() => {}} />
        )}
        {hasPerm(perms, 'view_contracts') && (
          <NavItem icon="📄" label="Contracts"     sub="Rights and licensing" onPress={() => {}} />
        )}
        {hasPerm(perms, 'use_dam') && (
          <NavItem icon="🗂" label="Digital Assets" sub="Asset library" onPress={() => {}} />
        )}
        {hasPerm(perms, 'manage_settings') && (
          <NavItem icon="⚙️" label="Settings"      sub="Network configuration" onPress={() => {}} />
        )}

        {/* Permissions summary */}
        <Text style={styles.sectionLabel}>Your access</Text>
        <View style={styles.permGrid}>
          {perms.map(p => (
            <View key={p} style={styles.permChip}>
              <Text style={styles.permTxt}>{p.replace(/_/g, ' ')}</Text>
            </View>
          ))}
        </View>
      </ScrollView>
    </Screen>
  );
}

function NavItem({ icon, label, sub, onPress }: {
  icon:    string;
  label:   string;
  sub?:    string;
  onPress: () => void;
}) {
  return (
    <TouchableOpacity style={styles.navItem} onPress={onPress} activeOpacity={0.7}>
      <Text style={styles.navIcon}>{icon}</Text>
      <View style={{ flex: 1 }}>
        <Text style={styles.navLabel}>{label}</Text>
        {sub && <Text style={styles.navSub}>{sub}</Text>}
      </View>
      <Text style={{ color: C.textMuted }}>›</Text>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  center:  { flex: 1, alignItems: 'center', justifyContent: 'center' },
  back:    { padding: 16, paddingBottom: 0 },
  backTxt: { color: C.textSub, fontSize: 14 },
  scroll:  { padding: 20, paddingBottom: 60 },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    marginBottom: 20,
  },
  networkIcon: {
    width: 52, height: 52, borderRadius: 14,
    backgroundColor: `${C.watch}22`,
    borderWidth: 1, borderColor: `${C.watch}44`,
    alignItems: 'center', justifyContent: 'center',
  },
  networkName:   { fontSize: 20, fontWeight: '800', color: C.text },
  networkHandle: { fontSize: 13, color: C.textMuted, marginTop: 2 },

  statsRow: { flexDirection: 'row', gap: 10, marginBottom: 8 },
  statCard: {
    flex: 1,
    backgroundColor: C.surface2, borderRadius: 12,
    borderWidth: 1, borderColor: C.border,
    padding: 14, alignItems: 'center',
  },
  statVal:   { fontSize: 22, fontWeight: '800', color: C.text },
  statLabel: { fontSize: 11, color: C.textMuted, marginTop: 2 },

  sectionLabel: {
    fontSize: 10, fontWeight: '800', color: C.textMuted,
    textTransform: 'uppercase', letterSpacing: 1.2,
    marginTop: 24, marginBottom: 10, paddingHorizontal: 2,
  },

  navItem: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: 14, paddingVertical: 14,
    borderRadius: 12, backgroundColor: C.surface2,
    borderWidth: 1, borderColor: C.border,
    marginBottom: 6,
  },
  navIcon:  { fontSize: 18, width: 24, textAlign: 'center' },
  navLabel: { fontSize: 14, fontWeight: '600', color: C.text },
  navSub:   { fontSize: 11, color: C.textMuted, marginTop: 2 },

  permGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  permChip: {
    paddingHorizontal: 10, paddingVertical: 5,
    backgroundColor: `${C.watch}15`, borderRadius: 20,
    borderWidth: 1, borderColor: `${C.watch}30`,
  },
  permTxt: { fontSize: 11, color: C.watch, fontWeight: '600' },
});
