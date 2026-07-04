/**
 * Magic link deep link handler.
 *
 * Safari's "Open in App" button redirects to:
 *   exp+mediaverse:///verify?token=<base64_token>
 *
 * Expo Router maps that to this screen. We call verifyMagicToken() which POSTs
 * the token to /api/auth/mobile/verify and stores the session JWT. The auth gate
 * in _layout.tsx then navigates to (app) automatically.
 */
import { useEffect, useState } from 'react';
import { View, Text, StyleSheet, TouchableOpacity } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { verifyMagicToken } from '@/lib/auth';
import { useAuth } from '@/hooks/useAuth';
import { Screen } from '@/components/ui/Screen';
import { C } from '@/lib/constants';

export default function VerifyScreen() {
  const { token } = useLocalSearchParams<{ token?: string }>();
  const { refresh } = useAuth();
  const router      = useRouter();

  const [error, setError] = useState('');

  useEffect(() => {
    if (!token) {
      setError('No token found in link.');
      return;
    }

    verifyMagicToken(token)
      .then(() => refresh())           // refresh triggers auth gate → navigates to (app)
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : 'Sign-in failed. The link may have expired.');
      });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  if (error) {
    return (
      <Screen>
        <View style={styles.center}>
          <View style={styles.iconWrap}>
            <Text style={styles.iconText}>✕</Text>
          </View>
          <Text style={styles.heading}>Link expired or invalid</Text>
          <Text style={styles.sub}>{error}</Text>
          <TouchableOpacity
            style={styles.btn}
            onPress={() => router.replace('/(auth)')}
          >
            <Text style={styles.btnTxt}>Try again</Text>
          </TouchableOpacity>
        </View>
      </Screen>
    );
  }

  return (
    <Screen>
      <View style={styles.center}>
        {/* Simple CSS-less spinner via border trick */}
        <View style={styles.spinner} />
        <Text style={styles.heading}>Signing you in…</Text>
        <Text style={styles.sub}>Just a moment.</Text>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  center:   { flex: 1, justifyContent: 'center', alignItems: 'center', paddingHorizontal: 28 },
  spinner: {
    width: 40, height: 40, borderRadius: 20,
    borderWidth: 2,
    borderColor:     'rgba(255,255,255,0.1)',
    borderTopColor:  'rgba(255,255,255,0.7)',
    marginBottom: 20,
  },
  iconWrap: {
    width: 56, height: 56, borderRadius: 28,
    backgroundColor: 'rgba(239,68,68,0.10)',
    alignItems: 'center', justifyContent: 'center',
    marginBottom: 16,
  },
  iconText: { fontSize: 22, color: C.danger },
  heading:  { fontSize: 22, fontWeight: '800', color: C.text, marginBottom: 8, textAlign: 'center' },
  sub:      { fontSize: 14, color: C.textSub, lineHeight: 20, textAlign: 'center', marginBottom: 28 },
  btn: {
    paddingVertical: 14, paddingHorizontal: 32, borderRadius: 100,
    backgroundColor: C.watch,
  },
  btnTxt: { fontSize: 14, fontWeight: '700', color: '#0a0a12' },
});
