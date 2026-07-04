/**
 * Sign-in screen — matches WeStreem web branding.
 *
 * Two sign-in methods:
 *   1. Google — opens westreem.com Google OAuth in an in-app browser (no proxy)
 *   2. Magic link — enter email, receive sign-in link
 */
import { useState } from 'react';
import {
  View, Text, TextInput, StyleSheet, KeyboardAvoidingView,
  Platform, TouchableOpacity, ActivityIndicator, ScrollView,
} from 'react-native';
import { Screen } from '@/components/ui/Screen';
import { sendMagicLink, signInWithGoogle } from '@/lib/auth';
import { useAuth } from '@/hooks/useAuth';
import { C } from '@/lib/constants';

// ── Google "G" SVG paths drawn with Views ────────────────────────────────────
// Since react-native-svg isn't installed we replicate the four-colour G with
// a simple white circle + "G" text — identical to the approach used on web
// for the fallback icon.
function GoogleIcon() {
  return (
    <View style={gIcon.circle}>
      <Text style={gIcon.letter}>G</Text>
    </View>
  );
}
const gIcon = StyleSheet.create({
  circle: {
    width: 20, height: 20, borderRadius: 10,
    backgroundColor: '#fff',
    alignItems: 'center', justifyContent: 'center',
  },
  letter: { fontSize: 12, fontWeight: '700', color: '#4285F4', lineHeight: 20 },
});

// ── Play icon (▶ in a green circle) ─────────────────────────────────────────
function PlayIcon() {
  return (
    <View style={play.wrap}>
      <Text style={play.symbol}>▶</Text>
    </View>
  );
}
const play = StyleSheet.create({
  wrap: {
    width: 48, height: 48, borderRadius: 24,
    backgroundColor: 'rgba(0,230,118,0.12)',
    alignItems: 'center', justifyContent: 'center',
  },
  symbol: { fontSize: 18, color: C.watch, marginLeft: 2 },
});

export default function SignInScreen() {
  const { refresh } = useAuth();

  const [email,         setEmail]         = useState('');
  const [loading,       setLoading]       = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);
  const [sent,          setSent]          = useState(false);
  const [error,         setError]         = useState('');

  // ── Google Sign-In ──────────────────────────────────────────────────────────
  // Opens the westreem.com Google OAuth flow in an in-app browser.
  // No third-party proxy — uses our already-registered redirect URI.
  async function handleGoogleSignIn() {
    setGoogleLoading(true);
    setError('');
    try {
      await signInWithGoogle();
      await refresh(); // triggers the auth gate → navigates to (app) and unmounts
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : 'Google sign-in failed';
      // Show all errors so the user sees what went wrong instead of infinite spin
      setError(msg);
    } finally {
      // Always stop the spinner — if navigation fired, component unmounts anyway
      setGoogleLoading(false);
    }
  }

  // ── Magic link ──────────────────────────────────────────────────────────────
  async function submit() {
    if (!email.trim()) return;
    setLoading(true); setError('');
    try {
      await sendMagicLink(email.trim().toLowerCase());
      setSent(true);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Something went wrong');
    } finally {
      setLoading(false);
    }
  }

  return (
    <Screen>
      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <ScrollView
          contentContainerStyle={s.scroll}
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
        >
          {/* ── Logo ─────────────────────────────────────────────────────────── */}
          <View style={s.logoSection}>
            <PlayIcon />
            <Text style={s.wordmark}>WeStreem</Text>
            <Text style={s.tagline}>Your streaming superapp</Text>
          </View>

          {!sent ? (
            /* ── Sign-in card ─────────────────────────────────────────────── */
            <View style={s.card}>
              <Text style={s.cardHeading}>Sign in</Text>
              <Text style={s.cardSub}>
                We'll send a magic link to your inbox — no password needed.
              </Text>

              {/* Google button */}
              <TouchableOpacity
                style={s.googleBtn}
                onPress={() => void handleGoogleSignIn()}
                disabled={googleLoading || loading}
                activeOpacity={0.7}
              >
                {googleLoading ? (
                  <ActivityIndicator size="small" color={C.text} />
                ) : (
                  <>
                    <GoogleIcon />
                    <Text style={s.googleTxt}>Continue with Google</Text>
                  </>
                )}
              </TouchableOpacity>

              {/* Divider */}
              <View style={s.divider}>
                <View style={s.dividerLine} />
                <Text style={s.dividerTxt}>OR</Text>
                <View style={s.dividerLine} />
              </View>

              {/* Email label + input */}
              <Text style={s.label}>Email address</Text>
              <TextInput
                style={s.input}
                value={email}
                onChangeText={setEmail}
                placeholder="you@example.com"
                placeholderTextColor="rgba(255,255,255,0.25)"
                keyboardType="email-address"
                autoCapitalize="none"
                autoCorrect={false}
                autoComplete="email"
                returnKeyType="send"
                onSubmitEditing={submit}
              />

              {error ? (
                <View style={s.errorBox}>
                  <Text style={s.errorTxt}>{error}</Text>
                </View>
              ) : null}

              {/* Submit */}
              <TouchableOpacity
                style={[s.submitBtn, (!email.trim() || loading || googleLoading) && s.submitDisabled]}
                onPress={submit}
                disabled={!email.trim() || loading || googleLoading}
                activeOpacity={0.8}
              >
                {loading ? (
                  <ActivityIndicator size="small" color="#0a0a12" />
                ) : (
                  <Text style={s.submitTxt}>Continue with email →</Text>
                )}
              </TouchableOpacity>

              {/* Terms */}
              <Text style={s.terms}>
                By continuing, you agree to our Terms of Service.{'\n'}
                New accounts are created automatically.
              </Text>
            </View>
          ) : (
            /* ── Check inbox card ─────────────────────────────────────────── */
            <View style={[s.card, s.sentCard]}>
              {/* Envelope icon */}
              <View style={s.envelopeWrap}>
                <Text style={s.envelopeIcon}>✉</Text>
              </View>

              <Text style={s.cardHeading}>Check your inbox</Text>
              <Text style={s.cardSub}>We sent a sign-in link to</Text>
              <Text style={s.sentEmail}>{email}</Text>

              <Text style={s.sentHint}>
                Tap the link in the email — Safari will open and give you the
                option to continue in the app or your browser. It expires in 24 hours.{'\n\n'}
                Don't see it? Check your spam folder.
              </Text>

              <TouchableOpacity
                onPress={() => { setSent(false); setError(''); }}
                style={s.backBtn}
              >
                <Text style={s.backTxt}>← Use a different email</Text>
              </TouchableOpacity>
            </View>
          )}
        </ScrollView>
      </KeyboardAvoidingView>
    </Screen>
  );
}

const s = StyleSheet.create({
  scroll: {
    flexGrow: 1,
    justifyContent: 'center',
    paddingHorizontal: 20,
    paddingVertical: 48,
  },

  // Logo section
  logoSection: { alignItems: 'center', marginBottom: 32, gap: 8 },
  wordmark:    { fontSize: 26, fontWeight: '800', color: C.text, letterSpacing: -0.5, marginTop: 4 },
  tagline:     { fontSize: 13, color: 'rgba(255,255,255,0.4)' },

  // Card
  card: {
    borderRadius: 20,
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.08)',
    backgroundColor: 'rgba(255,255,255,0.03)',
    padding: 28,
    gap: 12,
  },
  sentCard: { alignItems: 'center' },

  cardHeading: { fontSize: 20, fontWeight: '700', color: C.text },
  cardSub:     { fontSize: 13, color: 'rgba(255,255,255,0.4)', lineHeight: 19, marginBottom: 4 },

  // Google button
  googleBtn: {
    height: 50, borderRadius: 100,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 10,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)',
    backgroundColor: 'rgba(255,255,255,0.04)',
  },
  googleTxt: { fontSize: 14, fontWeight: '600', color: C.text },

  // Divider
  divider:     { flexDirection: 'row', alignItems: 'center', gap: 10, marginVertical: 2 },
  dividerLine: { flex: 1, height: 1, backgroundColor: 'rgba(255,255,255,0.07)' },
  dividerTxt:  { fontSize: 10, color: 'rgba(255,255,255,0.25)', letterSpacing: 1 },

  // Email field
  label: {
    fontSize: 11, fontWeight: '500', color: 'rgba(255,255,255,0.5)',
    textTransform: 'uppercase', letterSpacing: 0.8,
    marginBottom: -4,
  },
  input: {
    height: 48, borderRadius: 14,
    paddingHorizontal: 16,
    fontSize: 14, color: C.text,
    backgroundColor: 'rgba(255,255,255,0.06)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.10)',
  },

  // Error
  errorBox: {
    borderRadius: 10, paddingVertical: 8, paddingHorizontal: 12,
    backgroundColor: 'rgba(239,68,68,0.10)',
    borderWidth: 1, borderColor: 'rgba(239,68,68,0.15)',
  },
  errorTxt: { fontSize: 12, color: '#f87171', lineHeight: 17 },

  // Submit button
  submitBtn: {
    height: 50, borderRadius: 100,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: C.watch,
    marginTop: 2,
  },
  submitDisabled: { opacity: 0.4 },
  submitTxt: { fontSize: 14, fontWeight: '700', color: '#0a0a12' },

  // Terms
  terms: {
    fontSize: 10, color: 'rgba(255,255,255,0.25)',
    textAlign: 'center', lineHeight: 16, marginTop: 4,
  },

  // Sent state
  envelopeWrap: {
    width: 56, height: 56, borderRadius: 28,
    backgroundColor: 'rgba(0,230,118,0.10)',
    alignItems: 'center', justifyContent: 'center',
    marginBottom: 4,
  },
  envelopeIcon: { fontSize: 24, color: C.watch },
  sentEmail:    { fontSize: 14, fontWeight: '600', color: C.watch },
  sentHint:     { fontSize: 12, color: 'rgba(255,255,255,0.3)', lineHeight: 18, textAlign: 'center' },
  backBtn:      { marginTop: 8 },
  backTxt:      { fontSize: 13, color: 'rgba(255,255,255,0.4)' },
});
