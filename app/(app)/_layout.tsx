import { Tabs } from 'expo-router';
import { Text } from 'react-native';
import { C } from '@/lib/constants';

function TabIcon({ icon, focused }: { icon: string; focused: boolean }) {
  return (
    <Text style={{ fontSize: 22, opacity: focused ? 1 : 0.4 }}>{icon}</Text>
  );
}

export default function AppLayout() {
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarStyle: {
          backgroundColor: C.surface,
          borderTopColor:  C.border,
          borderTopWidth:  1,
        },
        tabBarActiveTintColor:   C.watch,
        tabBarInactiveTintColor: C.textMuted,
        tabBarLabelStyle: { fontSize: 11, fontWeight: '600' },
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          title: 'Home',
          tabBarIcon: ({ focused }) => <TabIcon icon="🏠" focused={focused} />,
        }}
      />
      <Tabs.Screen
        name="shorts"
        options={{
          title: 'Shorts',
          tabBarIcon: ({ focused }) => <TabIcon icon="▶" focused={focused} />,
        }}
      />
      <Tabs.Screen
        name="backstage"
        options={{
          title: 'Backstage',
          tabBarIcon: ({ focused }) => <TabIcon icon="🎬" focused={focused} />,
          href: '/(app)/backstage',
        }}
      />
      <Tabs.Screen
        name="profile"
        options={{
          title: 'Profile',
          tabBarIcon: ({ focused }) => <TabIcon icon="👤" focused={focused} />,
        }}
      />
      {/* Hidden routes — not tabs */}
      <Tabs.Screen name="watch/[id]"                         options={{ href: null }} />
      <Tabs.Screen name="backstage/network/[id]/index"       options={{ href: null }} />
      <Tabs.Screen name="backstage/network/[id]/members"     options={{ href: null }} />
      <Tabs.Screen name="backstage/network/[id]/revenue"     options={{ href: null }} />
    </Tabs>
  );
}
