import * as Linking from 'expo-linking';
import * as WebBrowser from 'expo-web-browser';
import { API_BASE } from './constants';
import { setSessionToken, clearSessionToken } from './session';

// ─── Send magic link email ────────────────────────────────────────────────────
export async function sendMagicLink(email: string): Promise<void> {
  // Extract the app scheme (e.g. "exp+mediaverse" in Expo Go, "mediaverse" in prod)
  const appScheme = Linking.createURL('').replace(':///', '://').replace('://', '').split('/')[0].split('?')[0];

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 25_000);
  try {
    const res = await fetch(`${API_BASE}/api/auth/magic`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, mobile: true, appScheme }),
      signal: ctrl.signal,
    });
    if (!res.ok) {
      const d = await res.json().catch(() => ({}));
      throw new Error(d.error ?? 'Failed to send magic link');
    }
  } catch (e: unknown) {
    if (e instanceof Error && e.name === 'AbortError') throw new Error('Request timed out');
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

// ─── Verify magic link token (mobile endpoint) ────────────────────────────────
// Called after the user taps the link and the deep link lands in the app.
// The server verifies the token and returns a session JWT we store locally.
export async function verifyMagicToken(token: string): Promise<void> {
  const res = await fetch(`${API_BASE}/api/auth/mobile/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token }),
  });
  if (!res.ok) {
    const d = await res.json().catch(() => ({}));
    throw new Error(d.error ?? 'Invalid or expired link');
  }
  const { sessionToken } = await res.json() as { sessionToken: string };
  await setSessionToken(sessionToken);
}

// ─── Sign in with Google (mobile) ────────────────────────────────────────────
// Opens the existing westreem.com Google OAuth flow in an in-app browser.
// Because the redirect URI is our own domain (already registered in Google Cloud
// Console) there are no proxy/policy issues.
//
// Flow:
//   1. Open https://www.westreem.com/api/auth/google?mobile=true&appScheme=...
//   2. Google OAuth completes through our trusted redirect URI
//   3. Our callback redirects to {appScheme}:///auth/google?sessionToken=JWT
//   4. WebBrowser detects the app-scheme URL, closes, returns it to us
//   5. We extract the JWT and store it
export async function signInWithGoogle(): Promise<void> {
  // Derive the current app scheme (exp+mediaverse in Expo Go, mediaverse in prod)
  const raw = Linking.createURL('');
  const appScheme = raw
    .replace(':///', '://')
    .replace('://', '')
    .split('/')[0]
    .split('?')[0];

  const authUrl =
    `${API_BASE}/api/auth/google` +
    `?mobile=true&appScheme=${encodeURIComponent(appScheme)}`;

  console.log('[Google] opening auth session, scheme:', appScheme);

  const result = await WebBrowser.openAuthSessionAsync(
    authUrl,
    `${appScheme}://`,  // prefix: browser closes when redirect starts with this
  );

  console.log('[Google] result type:', result.type);
  if (result.type === 'success') console.log('[Google] result url:', result.url);

  if (result.type !== 'success') {
    throw new Error(`Sign-in ${result.type}`); // 'cancel' or 'dismiss'
  }

  // Parse sessionToken from the returned deep-link URL
  const parsed = Linking.parse(result.url);
  console.log('[Google] parsed params:', JSON.stringify(parsed.queryParams));
  const sessionToken = parsed.queryParams?.sessionToken as string | undefined;
  if (!sessionToken) throw new Error('No session token in redirect URL');

  await setSessionToken(sessionToken);
  console.log('[Google] session token stored ✓');
}

// ─── Sign out ─────────────────────────────────────────────────────────────────
export async function signOut(): Promise<void> {
  await clearSessionToken();
}
