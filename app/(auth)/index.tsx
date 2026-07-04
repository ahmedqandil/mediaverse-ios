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
import Svg, { Path } from 'react-native-svg';
import { Screen } from '@/components/ui/Screen';
import { sendMagicLink, signInWithGoogle } from '@/lib/auth';
import { useAuth } from '@/hooks/useAuth';
import { C } from '@/lib/constants';

// ── Official Google "G" logo (4-colour SVG) ───────────────────────────────────
function GoogleIcon() {
  return (
    <View style={{ width: 20, height: 20 }}>
      <Svg viewBox="0 0 24 24" width={20} height={20}>
        {/* Blue */}
        <Path
          d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
          fill="#4285F4"
        />
        {/* Green */}
        <Path
          d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
          fill="#34A853"
        />
        {/* Yellow */}
        <Path
          d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.84z"
          fill="#FBBC05"
        />
        {/* Red */}
        <Path
          d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
          fill="#EA4335"
        />
      </Svg>
    </View>
  );
}

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
