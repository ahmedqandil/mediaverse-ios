import { SafeAreaView, StatusBar, StyleSheet, View, type ViewStyle } from 'react-native';
import { C } from '@/lib/constants';

interface ScreenProps {
  children: React.ReactNode;
  style?:   ViewStyle;
  edges?:   ('top' | 'bottom' | 'left' | 'right')[];
}

export function Screen({ children, style }: ScreenProps) {
  return (
    <SafeAreaView style={[styles.safe, style]}>
      <StatusBar barStyle="light-content" backgroundColor={C.bg} />
      {children}
    </SafeAreaView>
  );
}

export function ScreenFull({ children, style }: ScreenProps) {
  return (
    <View style={[styles.full, style]}>
      <StatusBar barStyle="light-content" backgroundColor="transparent" translucent />
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: C.bg },
  full: { flex: 1, backgroundColor: C.bg },
});
