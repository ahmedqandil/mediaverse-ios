import {
  TouchableOpacity, Text, ActivityIndicator, StyleSheet, type ViewStyle,
} from 'react-native';
import { C } from '@/lib/constants';

interface ButtonProps {
  onPress:   () => void;
  label:     string;
  variant?:  'primary' | 'secondary' | 'ghost' | 'danger';
  loading?:  boolean;
  disabled?: boolean;
  style?:    ViewStyle;
  small?:    boolean;
}

export function Button({
  onPress, label, variant = 'primary', loading, disabled, style, small,
}: ButtonProps) {
  const bg = {
    primary:   C.watch,
    secondary: C.surface2,
    ghost:     'transparent',
    danger:    C.danger,
  }[variant];

  const color = variant === 'primary' ? '#000' : C.text;
  const borderColor = variant === 'ghost' ? C.border2 : 'transparent';

  return (
    <TouchableOpacity
      onPress={onPress}
      disabled={disabled || loading}
      activeOpacity={0.75}
      style={[
        styles.base,
        small && styles.small,
        { backgroundColor: bg, borderColor, borderWidth: variant === 'ghost' ? 1 : 0 },
        (disabled || loading) && styles.disabled,
        style,
      ]}
    >
      {loading
        ? <ActivityIndicator size="small" color={color} />
        : <Text style={[styles.label, small && styles.labelSmall, { color }]}>{label}</Text>
      }
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  base: {
    height: 52, borderRadius: 14,
    alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 20,
  },
  small: { height: 38, borderRadius: 10 },
  disabled: { opacity: 0.45 },
  label: { fontSize: 15, fontWeight: '700', letterSpacing: 0.1 },
  labelSmall: { fontSize: 13 },
});
