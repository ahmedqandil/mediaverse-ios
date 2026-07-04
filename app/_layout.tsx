import { useEffect } from 'react';
import { View } from 'react-native';
import { Stack, useRouter, useSegments } from 'expo-router';
import { useAuth } from '@/hooks/useAuth';
import { C } from '@/lib/constants';

export default function RootLayout() {
  const { loading, authenticated } = useAuth();
  const segments = useSegments();
  const router   = useRouter();

  // Deep links (magic link + Google callback) are handled by their route files:
  //   app/(auth)/verify.tsx  → exp+mediaverse:///verify?token=...

  // ── Auth gate ─────────────────────────────────────────────────────────────
  useEffect(() => {
    if (loading) return;
    const inAuth = segments[0] === '(auth)';
    if (!authenticated && !inAuth) router.replace('/(auth)');
    if (authenticated  &&  inAuth) router.replace('/(app)');
  }, [loading, authenticated, segments, router]);

  return (
    <View style={{ flex: 1 }}>
      <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: C.bg } }}>
        <Stack.Screen name="(auth)" />
        <Stack.Screen name="(app)"  />
      </Stack>
    </View>
  );
}
