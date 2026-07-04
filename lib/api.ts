import { API_BASE, SESSION_COOKIE } from './constants';
import { getSessionToken } from './session';

// ─── Core fetch wrapper ───────────────────────────────────────────────────────

export async function apiFetch(
  path: string,
  init?: RequestInit & { skipAuth?: boolean },
): Promise<Response> {
  const token = init?.skipAuth ? null : await getSessionToken();

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(init?.headers as Record<string, string> | undefined),
  };
  if (token) {
    headers['Cookie'] = `${SESSION_COOKIE}=${token}`;
  }

  return fetch(`${API_BASE}${path}`, { ...init, headers });
}

// ─── Typed helpers ────────────────────────────────────────────────────────────

export async function apiGet<T>(path: string): Promise<T> {
  const res = await apiFetch(path);
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new ApiError(res.status, data.error ?? `HTTP ${res.status}`);
  }
  return res.json() as Promise<T>;
}

export async function apiPost<T>(path: string, body?: unknown): Promise<T> {
  const res = await apiFetch(path, {
    method: 'POST',
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new ApiError(res.status, data.error ?? `HTTP ${res.status}`);
  }
  return res.json() as Promise<T>;
}

export async function apiDelete<T>(path: string): Promise<T> {
  const res = await apiFetch(path, { method: 'DELETE' });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new ApiError(res.status, data.error ?? `HTTP ${res.status}`);
  }
  return res.json() as Promise<T>;
}

// ─── Error class ─────────────────────────────────────────────────────────────

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = 'ApiError';
  }
}
