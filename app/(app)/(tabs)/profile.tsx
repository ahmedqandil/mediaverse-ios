import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { Screen } from '@/components/ui/Screen';
import { Button } from '@/components/ui/Button';
import { useAuth } from '@/hooks/useAuth';
import { C } from '@/lib/constants';

export default function ProfileScreen() {
  const { user, logout } = useAuth();

  return (
    <Screen>
      <View style={styles.wrap}>
        <Text style={styles.heading}>Profile</Text>

        {/* Avatar */}
        <View style={styles.avatar}>
          <Text style={styles.avatarTxt}>
            {user?.name?.charAt(0).toUpperCase() ?? '?'}
          </Text>
        </View>

        <Text style={styles.name}>{user?.name ?? '—'}</Text>
        <Text style={styles.email}>{user?.email}</Text>

        {user?.role && user.role !== 'VIEWER' && (
          <View style={styles.badge}>
            <Text style={styles.badgeTxt}>{user.role}</Text>
          </View>
        )}

        <View style={styles.divider} />

        <Button
          onPress={logout}
          label="Sign out"
          variant="ghost"
        />
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  wrap:      { flex: 1, alignItems: 'center', paddingTop: 40, paddingHorizontal: 28 },
  heading:   { fontSize: 22, fontWeight: '800', color: C.text, alignSelf: 'flex-start', marginBottom: 32 },
  avatar:    {
    width: 80, height: 80, borderRadius: 40,
    backgroundColor: C.surface2, alignItems: 'center', justifyContent: 'center',
    borderWidth: 2, borderColor: C.watch,
    marginBottom: 14,
  },
  avatarTxt: { fontSize: 30, color: C.text, fontWeight: '700' },
  name:      { fontSize: 18, fontWeight: '700', color: C.text },
  email:     { fontSize: 13, color: C.textSub, marginTop: 4 },
  badge:     {
    marginTop: 10, paddingHorizontal: 10, paddingVertical: 4,
    borderRadius: 20, backgroundColor: `${C.watch}22`,
    borderWidth: 1, borderColor: `${C.watch}44`,
  },
  badgeTxt:  { fontSize: 11, fontWeight: '700', color: C.watch, textTransform: 'uppercase', letterSpacing: 1 },
  divider:   { width: '100%', height: 1, backgroundColor: C.border, marginVertical: 28 },
});
