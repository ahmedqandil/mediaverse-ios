/**
 * Backstage hub — context switcher + role-gated nav.
 * Mirrors BackstageSidebarUI.tsx: only shows items the user has permission for.
 * Permission strings come from GET /api/me/network-permissions/[networkId].
 */
import { useEffect, useState } from 'react';
import {
  ScrollView, View, Text, TouchableOpacity,
  ActivityIndicator, StyleSheet,
} from 'react-native';
import { useRouter } from 'expo-router';
import { Screen } from '@/components/ui/Screen';
import { useActiveContext } from '@/hooks/useActiveContext';
import { useAuth } from '@/hooks/useAuth';
import { apiGet } from '@/lib/api';
import { C } from '@/lib/constants';
import type { ActiveContext } from '@/lib/types';

// ── Permission → tab map (mirrors TAB_PERMISSION on web) ──────────────────────
const TAB_PERMISSION: Record<string, string> = {
  channels:    'manage_channels',
  shows:       'manage_shows',
  schedule:    'view_schedule',
  contracts:   'view_contracts',
  dam:         'use_dam',
  products:    'manage_settings',
  revenue:     'view_analytics',
  analytics:   'view_analytics',
  members:     'manage_members',
  'audit-log': 'manage_members',
  settings:    'manage_settings',
};

function hasPerm(
  isPlatformAdmin: boolean,
  permissions: string[],
  perm: string,
): boolean {
  return isPlatformAdmin || permissions.includes(perm);
}

export default function BackstageScreen() {
  const router = useRouter();
  const { user } = useAuth();
  const { loading, ctx, allContexts, switchCtx } = useActiveContext();
  const [permissions, setPermissions] = useState<string[]>([]);
  const [permLoading, setPermLoading] = useState(false);
  const [ctxOpen, setCtxOpen]         = useState(false);

  const isPlatformAdmin = user?.role === 'ADMIN' || user?.role === 'SUPER_ADMIN';

  // Fetch permissions when context changes to a network
  useEffect(() => {
    if (ctx?.type !== 'network') { setPermissions([]); return; }
    setPermLoading(true);
    apiGet<string[]>(`/api/me/network-permissions/${ctx.id}`)
      .then(setPermissions)
      .catch(() => setPermissions([]))
      .finally(() => setPermLoading(false));
  }, [ctx]);

  const has = (perm: string) => hasPerm(isPlatformAdmin, permissions, perm);

  if (loading || permLoading) {
    return <Screen style={styles.center}><ActivityIndicator color={C.watch} /></Screen>;
  }

  return (
    <Screen>
      <ScrollView contentContainerStyle={styles.scroll}>
        <Text style={styles.heading}>Backstage</Text>

        {/* ── Context switcher ── */}
        <TouchableOpacity
          style={styles.ctxBtn}
          onPress={() => setCtxOpen(o => !o)}
        >
          <View style={[styles.ctxIcon, { backgroundColor: ctx?.type === 'admin' ? '#fbbf2433' : `${C.watch}25` }]}>
            <Text style={{ color: ctx?.type === 'admin' ? C.amber : C.watch, fontWeight: '800', fontSize: 13 }}>
              {ctx?.type === 'admin' ? 'A' : ctx?.type === 'network' ? 'N' : 'C'}
            </Text>
          </View>
          <View style={{ flex: 1 }}>
            <Text style={styles.ctxName}>{ctx?.type === 'admin' ? 'System Admin' : (ctx?.name ?? 'Select workspace')}</Text>
            <Text style={styles.ctxType}>{ctx?.type ?? 'none'}</Text>
          </View>
          <Text style={{ color: C.textMuted }}>⌄</Text>
        </TouchableOpacity>

        {/* Switcher dropdown */}
        {ctxOpen && (
          <View style={styles.ctxList}>
            {allContexts.map(c => {
              const active = c.type === ctx?.type && c.id === ctx?.id;
              return (
                <TouchableOpacity
                  key={`${c.type}-${c.id}`}
                  style={[styles.ctxItem, active && styles.ctxItemActive]}
                  onPress={async () => { await switchCtx(c); setCtxOpen(false); }}
                >
                  <Text style={styles.ctxItemName}>{c.name}</Text>
                  <Text style={styles.ctxItemType}>{c.type}</Text>
                </TouchableOpacity>
              );
            })}
          </View>
        )}

        {/* ── Admin workspace ── */}
        {ctx?.type === 'admin' && (
          <View style={styles.navGroup}>
            <Text style={styles.groupLabel}>System</Text>
            <NavItem icon="🛡" label="Users"       onPress={() => {}} />
            <NavItem icon="🌐" label="Networks"    onPress={() => {}} />
            <NavItem icon="📡" label="Channels"    onPress={() => {}} />
            <Text style={styles.groupLabel}>Billing</Text>
            <NavItem icon="📊" label="Revenue"     onPress={() => router.push('/(app)/backstage/platform-revenue')} />
            <NavItem icon="⚡" label="Store Fees"  onPress={() => {}} />
          </View>
        )}

        {/* ── Network workspace — role-gated ── */}
        {ctx?.type === 'network' && (
          <View style={styles.navGroup}>
            {/* Content section */}
            {(has('manage_channels') || has('manage_shows') || has('view_schedule')) && (
              <Text style={styles.groupLabel}>Content</Text>
            )}
            {has('manage_channels') && (
              <NavItem icon="📡" label="Channels" onPress={() => {}} />
            )}
            {ctx.canCreateShows !== false && has('manage_shows') && (
              <NavItem icon="🎬" label="Shows" onPress={() => {}} />
            )}
            {ctx.canCreateShows !== false && has('view_schedule') && (
              <NavItem icon="📅" label="Scheduler" onPress={() => {}} />
            )}
            {ctx.canCreateShows !== false && has('view_contracts') && (
              <NavItem icon="📄" label="Contracts" onPress={() => {}} />
            )}
            {ctx.damEnabled && has('use_dam') && (
              <NavItem icon="🗂" label="Digital Assets" onPress={() => {}} />
            )}

            {/* Business section */}
            {(has('manage_settings') || has('view_analytics')) && (
              <Text style={styles.groupLabel}>Business</Text>
            )}
            {has('manage_settings') && (
              <NavItem icon="🏷" label="Products" onPress={() => {}} />
            )}
            {has('view_analytics') && (
              <NavItem
                icon="📊"
                label="Revenue"
                onPress={() => router.push(`/(app)/backstage/network/${ctx.id}/revenue`)}
              />
            )}

            {/* Manage section */}
            {(has('manage_members') || has('manage_settings')) && (
              <Text style={styles.groupLabel}>Manage</Text>
            )}
            {has('manage_members') && (
              <NavItem
                icon="👥"
                label="Members"
                onPress={() => router.push(`/(app)/backstage/network/${ctx.id}/members`)}
              />
            )}
            {has('manage_settings') && (
              <NavItem
                icon="⚙️"
                label="Settings"
                onPress={() => router.push(`/(app)/backstage/network/${ctx.id}/index`)}
              />
            )}
          </View>
        )}

        {/* ── Channel workspace ── */}
        {ctx?.type === 'channel' && ctx.channelId && (
          <View style={styles.navGroup}>
            <Text style={styles.groupLabel}>Content</Text>
            <NavItem icon="🎬" label="Videos"    onPress={() => {}} />
            <NavItem icon="▶️" label="Playlists" onPress={() => {}} />
            <Text style={styles.groupLabel}>Grow</Text>
            <NavItem icon="📊" label="Analytics" onPress={() => {}} />
            <Text style={styles.groupLabel}>Configure</Text>
            <NavItem icon="⚙️" label="Settings"  onPress={() => {}} />
          </View>
        )}

        {!ctx && (
          <View style={styles.empty}>
            <Text style={styles.emptyTxt}>No workspace selected.</Text>
            <Text style={styles.emptyTxt}>Switch context above to get started.</Text>
          </View>
        )}
      </ScrollView>
    </Screen>
  );
}

function NavItem({ icon, label, onPress }: { icon: string; label: string; onPress: () => void }) {
  return (
    <TouchableOpacity style={styles.navItem} onPress={onPress} activeOpacity={0.7}>
      <Text style={styles.navIcon}>{icon}</Text>
      <Text style={styles.navLabel}>{label}</Text>
      <Text style={{ color: C.textMuted }}>›</Text>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  center:  { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll:  { padding: 20, paddingBottom: 60 },
  heading: { fontSize: 22, fontWeight: '800', color: C.text, marginBottom: 20 },

  ctxBtn:  {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: C.surface2, borderRadius: 14,
    padding: 14, borderWidth: 1, borderColor: C.border,
  },
  ctxIcon: { width: 36, height: 36, borderRadius: 10, alignItems: 'center', justifyContent: 'center' },
  ctxName: { fontSize: 14, fontWeight: '700', color: C.text },
  ctxType: { fontSize: 11, color: C.textMuted, textTransform: 'capitalize', marginTop: 2 },

  ctxList: {
    marginTop: 4, borderRadius: 14,
    backgroundColor: C.surface2, borderWidth: 1, borderColor: C.border,
    overflow: 'hidden',
  },
  ctxItem:       { paddingHorizontal: 16, paddingVertical: 12, gap: 2 },
  ctxItemActive: { backgroundColor: 'rgba(255,255,255,0.06)' },
  ctxItemName:   { fontSize: 14, fontWeight: '600', color: C.text },
  ctxItemType:   { fontSize: 11, color: C.textMuted, textTransform: 'capitalize' },

  navGroup:    { marginTop: 24, gap: 4 },
  groupLabel:  {
    fontSize: 10, fontWeight: '800', color: C.textMuted,
    textTransform: 'uppercase', letterSpacing: 1.2,
    marginTop: 16, marginBottom: 4, paddingHorizontal: 4,
  },
  navItem: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: 14, paddingVertical: 14,
    borderRadius: 12, backgroundColor: C.surface2,
    borderWidth: 1, borderColor: C.border,
    marginBottom: 2,
  },
  navIcon:  { fontSize: 18, width: 24, textAlign: 'center' },
  navLabel: { flex: 1, fontSize: 14, fontWeight: '600', color: C.text },

  empty:    { alignItems: 'center', paddingTop: 60, gap: 6 },
  emptyTxt: { color: C.textMuted, fontSize: 13, textAlign: 'center' },
});
