import { useState, useEffect, useCallback } from 'react';
import { apiGet } from '@/lib/api';
import { hasSession } from '@/lib/session';
import { signOut } from '@/lib/auth';
import type { SessionUser } from '@/lib/types';

interface AuthState {
  loading:       boolean;
  authenticated: boolean;
  user:          SessionUser | null;
  refresh:       () => Promise<void>;
  logout:        () => Promise<void>;
}

export function useAuth(): AuthState {
  const [loading, setLoading]           = useState(true);
  const [authenticated, setAuthenticated] = useState(false);
  const [user, setUser]                 = useState<SessionUser | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const hasToken = await hasSession();
      if (!hasToken) { setAuthenticated(false); setUser(null); return; }
      const me = await apiGet<SessionUser>('/api/me');
      setUser(me);
      setAuthenticated(true);
    } catch {
      setAuthenticated(false);
      setUser(null);
    } finally {
      setLoading(false);
    }
  }, []);

  const logout = useCallback(async () => {
    await signOut();
    setAuthenticated(false);
    setUser(null);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  return { loading, authenticated, user, refresh, logout };
}
