import { Stack } from 'expo-router';
import { C } from '@/lib/constants';

/**
 * App-level Stack navigator.
 *
 * (tabs)/ → all tab screens (home, shorts, backstage, profile)
 * watch/[id] and watch/episode/[id] → full-screen detail screens,
 *   pushed on top of tabs so the tab bar disappears and back nav works.
 * backstage/network/[id]/* → backstage detail Stack screens.
 */
export default function AppLayout() {
  return (
    <Stack
      screenOptions={{
        headerShown: false,
        contentStyle: { backgroundColor: C.bg },
      }}
    >
      <Stack.Screen name="(tabs)" />
      <Stack.Screen name="watch/[id]" />
      <Stack.Screen name="watch/episode/[id]" />
      <Stack.Screen name="backstage/network/[id]/index" />
      <Stack.Screen name="backstage/network/[id]/members" />
      <Stack.Screen name="backstage/network/[id]/revenue" />
    </Stack>
  );
}
