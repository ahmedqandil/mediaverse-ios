import { useState, useEffect, useCallback } from 'react';
import { apiGet, apiPost } from '@/lib/api';
import type { ActiveContext } from '@/lib/types';

interface ActiveContextState {
  loading:     boolean;
  ctx:         ActiveContext | null;
  allContexts: ActiveContext[];
  switchCtx:   (next: ActiveContext) => Promise<void>;
  refresh:     () => Promise<void>;
}

export function useActiveContext(): ActiveContextState {
  const [loading, setLoading]         = useState(true);
  const [ctx, setCtx]                 = useState<ActiveContext | null>(null);
  const [allContexts, setAllContexts] = useState<ActiveContext[]>([]);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const [current, all] = await Promise.all([
        apiGet<ActiveContext | null>('/api/me/active-context'),
        apiGet<ActiveContext[]>('/api/me/contexts'),
      ]);
      setCtx(current);
      setAllContexts(all ?? []);
    } catch {
      // session likely expired — caller should handle re-auth
    } finally {
      setLoading(false);
    }
  }, []);

  const switchCtx = useCallback(async (next: ActiveContext) => {
    await apiPost('/api/me/active-context', next);
    setCtx(next);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  return { loading, ctx, allContexts, switchCtx, refresh };
}
