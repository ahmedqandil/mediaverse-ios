/**
 * Network members screen — mirrors web NetworkBackstageClient.tsx members tab.
 * Permission-gated: only accessible to members with "manage_members".
 */
import { useCallback, useEffect, useState } from 'react';
import {
  ScrollView, View, Text, TextInput, TouchableOpacity,
  ActivityIndicator, Alert, StyleSheet, RefreshControl,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { Screen } from '@/components/ui/Screen';
import { Button } from '@/components/ui/Button';
import { apiGet, apiPost, apiDelete, ApiError } from '@/lib/api';
import { C } from '@/lib/constants';

type Member = {
  id:          string;
  role:        string;
  permissions: { grant?: string[]; deny?: string[] };
  invitedBy:   string | null;
  createdAt:   string;
  user:        { id: string; name: string | null; email: string | null };
};

const ROLES = ['viewer', 'analyst', 'rights_manager', 'editor', 'admin'] as const;
type Role = typeof ROLES[number];

const ROLE_LABELS: Record<Role, string> = {
  viewer:         'Viewer',
  analyst:        'Analyst',
  rights_manager: 'Rights Manager',
  editor:         'Editor',
  admin:          'Admin',
};

const ROLE_COLORS: Record<Role, string> = {
  viewer:         C.textMuted,
  analyst:        '#60a5fa',
  rights_manager: C.amber,
  editor:         '#a78bfa',
  admin:          C.watch,
};

export default function MembersScreen() {
  const { id: networkId } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();

  const [members,     setMembers]     = useState<Member[]>([]);
  const [createdBy,   setCreatedBy]   = useState<string | null>(null);
  const [loading,     setLoading]     = useState(true);
  const [refreshing,  setRefreshing]  = useState(false);
  const [inviteEmail, setInviteEmail] = useState('');
  const [inviteRole,  setInviteRole]  = useState<Role>('viewer');
  const [inviting,    setInviting]    = useState(false);

  const load = useCallback(async () => {
    try {
      const d = await apiGet<{ members: Member[]; createdBy: string | null }>(
        `/api/backstage/network/${networkId}/members`,
      );
      setMembers(d.members ?? []);
      setCreatedBy(d.createdBy ?? null);
    } catch {
      //
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [networkId]);

  useEffect(() => { load(); }, [load]);

  async function invite() {
    const email = inviteEmail.trim().toLowerCase();
    if (!email) { Alert.alert('Email required'); return; }
    setInviting(true);
    try {
      await apiPost(`/api/backstage/network/${networkId}/members`, { email, role: inviteRole });
      setInviteEmail('');
      load();
    } catch (e) {
      const msg = e instanceof ApiError ? e.message : 'Failed to invite member';
      Alert.alert('Invite failed', msg);
    } finally {
      setInviting(false);
    }
  }

  async function removeMember(userId: string, name: string | null) {
    Alert.alert(
      'Remove member',
      `Remove ${name ?? userId} from this network?`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Remove', style: 'destructive',
          onPress: async () => {
            try {
              await apiDelete(`/api/backstage/network/${networkId}/members/${userId}`);
              load();
            } catch {
              Alert.alert('Error', 'Could not remove member');
            }
          },
        },
      ],
    );
  }

  if (loading) {
    return <Screen style={styles.center}><ActivityIndicator color={C.watch} /></Screen>;
  }

  return (
    <Screen>
      {/* Back */}
      <TouchableOpacity onPress={() => router.back()} style={styles.back}>
        <Text style={styles.backTxt}>← Members</Text>
      </TouchableOpacity>

      <ScrollView
        contentContainerStyle={styles.scroll}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); load(); }} tintColor={C.watch} />
        }
      >
        {/* ── Invite form ── */}
        <View style={styles.card}>
          <Text style={styles.cardTitle}>Invite member</Text>
          <TextInput
            style={styles.input}
            placeholder="Email address"
            placeholderTextColor={C.textMuted}
            value={inviteEmail}
            onChangeText={setInviteEmail}
            keyboardType="email-address"
            autoCapitalize="none"
            returnKeyType="done"
          />

          {/* Role picker */}
          <View style={styles.rolePicker}>
            {ROLES.map(r => (
              <TouchableOpacity
                key={r}
                style={[styles.roleChip, inviteRole === r && { borderColor: ROLE_COLORS[r], backgroundColor: `${ROLE_COLORS[r]}20` }]}
                onPress={() => setInviteRole(r)}
              >
                <Text style={[styles.roleChipTxt, { color: inviteRole === r ? ROLE_COLORS[r] : C.textMuted }]}>
                  {ROLE_LABELS[r]}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          <Button
            label={inviting ? 'Inviting…' : 'Send invite'}
            onPress={invite}
            loading={inviting}
          />
        </View>

        {/* ── Members list ── */}
        <Text style={styles.sectionLabel}>{members.length} Member{members.length !== 1 ? 's' : ''}</Text>

        {members.map(m => {
          const isOwner = m.user.id === createdBy;
          const role    = m.role as Role;
          return (
            <View key={m.id} style={styles.memberRow}>
              {/* Avatar */}
              <View style={[styles.avatar, { backgroundColor: `${ROLE_COLORS[role] ?? C.watch}22` }]}>
                <Text style={[styles.avatarTxt, { color: ROLE_COLORS[role] ?? C.watch }]}>
                  {(m.user.name ?? m.user.email ?? '?').charAt(0).toUpperCase()}
                </Text>
              </View>

              {/* Info */}
              <View style={{ flex: 1 }}>
                <View style={styles.memberNameRow}>
                  <Text style={styles.memberName}>{m.user.name ?? m.user.email ?? 'Unknown'}</Text>
                  {isOwner && <View style={styles.ownerBadge}><Text style={styles.ownerBadgeTxt}>Owner</Text></View>}
                </View>
                <Text style={styles.memberEmail}>{m.user.email}</Text>
                <View style={[styles.roleBadge, { backgroundColor: `${ROLE_COLORS[role]}20`, borderColor: `${ROLE_COLORS[role]}40` }]}>
                  <Text style={[styles.roleBadgeTxt, { color: ROLE_COLORS[role] ?? C.textSub }]}>
                    {ROLE_LABELS[role] ?? role}
                  </Text>
                </View>
              </View>

              {/* Remove (not for owner) */}
              {!isOwner && (
                <TouchableOpacity
                  onPress={() => removeMember(m.user.id, m.user.name)}
                  style={styles.removeBtn}
                  hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
                >
                  <Text style={styles.removeTxt}>✕</Text>
                </TouchableOpacity>
              )}
            </View>
          );
        })}
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  center:  { flex: 1, alignItems: 'center', justifyContent: 'center' },
  back:    { padding: 16, paddingBottom: 0 },
  backTxt: { color: C.textSub, fontSize: 14 },
  scroll:  { padding: 20, paddingBottom: 60 },

  card: {
    backgroundColor: C.surface2, borderRadius: 16,
    borderWidth: 1, borderColor: C.border,
    padding: 16, gap: 12,
  },
  cardTitle: { fontSize: 15, fontWeight: '700', color: C.text },
  input: {
    borderWidth: 1, borderColor: C.border, borderRadius: 10,
    paddingHorizontal: 14, paddingVertical: 12,
    color: C.text, fontSize: 14, backgroundColor: C.bg,
  },
  rolePicker: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  roleChip:   {
    paddingHorizontal: 10, paddingVertical: 6,
    borderRadius: 20, borderWidth: 1, borderColor: C.border,
  },
  roleChipTxt: { fontSize: 11, fontWeight: '600' },

  sectionLabel: {
    fontSize: 10, fontWeight: '800', color: C.textMuted,
    textTransform: 'uppercase', letterSpacing: 1.2,
    marginTop: 24, marginBottom: 10, paddingHorizontal: 2,
  },

  memberRow: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: C.surface2, borderRadius: 14,
    borderWidth: 1, borderColor: C.border,
    padding: 12, marginBottom: 6,
  },
  avatar:    { width: 40, height: 40, borderRadius: 20, alignItems: 'center', justifyContent: 'center' },
  avatarTxt: { fontSize: 16, fontWeight: '800' },

  memberNameRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  memberName:    { fontSize: 14, fontWeight: '700', color: C.text },
  memberEmail:   { fontSize: 12, color: C.textMuted, marginTop: 1 },

  ownerBadge: {
    paddingHorizontal: 6, paddingVertical: 2,
    backgroundColor: '#fbbf2422', borderRadius: 10,
    borderWidth: 1, borderColor: '#fbbf2440',
  },
  ownerBadgeTxt: { fontSize: 10, fontWeight: '700', color: C.amber },

  roleBadge: {
    alignSelf: 'flex-start', marginTop: 5,
    paddingHorizontal: 8, paddingVertical: 3,
    borderRadius: 10, borderWidth: 1,
  },
  roleBadgeTxt: { fontSize: 11, fontWeight: '600' },

  removeBtn: { padding: 4 },
  removeTxt: { fontSize: 16, color: C.danger },
});
