// ─── API ──────────────────────────────────────────────────────────────────────
// Replace with your actual Vercel domain before running
export const API_BASE = 'https://www.westreem.com';

// ─── Colors (mirrors web --watch / design tokens) ─────────────────────────────
export const C = {
  bg:       '#0a0a0f',
  surface:  '#111116',
  surface2: '#18181e',
  border:   'rgba(255,255,255,0.06)',
  border2:  'rgba(255,255,255,0.10)',
  watch:    '#00e676',   // primary green accent
  listen:   '#7c6af7',  // purple accent
  text:     '#ffffff',
  textSub:  'rgba(255,255,255,0.5)',
  textMuted:'rgba(255,255,255,0.3)',
  danger:   '#ef4444',
  amber:    '#fbbf24',
} as const;

// ─── Session cookie name (must match web app) ──────────────────────────────────
export const SESSION_COOKIE = 'next-auth.session-token';
export const SESSION_KEY     = 'mv_session_token';
