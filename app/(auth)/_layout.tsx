import { Stack } from 'expo-router';
import { C } from '@/lib/constants';

export default function AuthLayout() {
  return (
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: C.bg } }} />
  );
}
