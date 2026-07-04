/**
 * Platform admin revenue screen — mirrors web AdminRevenueClient.tsx.
 * Only accessible with admin context (ADMIN / SUPER_ADMIN role).
 * Pulls from /api/admin/revenue
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  ScrollView, View, Text, TouchableOpacity, ActivityIndicator,
  StyleSheet, RefreshControl,
} from 'react-native';
import { useRouter } from 'expo-router';
import { Screen } from '@/components/ui/Screen';
import { apiGet } from '@/lib/api';
import { C } from '@/lib/constants';

type ByCurrency = Record<string, number>;

interface KPIs {
  totalRevenue:      ByCurrency;
  mrr:               ByCurrency;
  platformShare:     ByCurrency;
  totalOrders:       number;
  activeSubscribers: number;
}
interface ByNetwork {
  networkId:   string;
  networkName: string;
  byCurrency:  ByCurrency;
  orderCount:  number;
}
interface ByProduct {
  productId:   string;
  productName: string;
  networkName: string;
  type:        string;
  byCurrency:  ByCurrency;
  orderCount:  number;
}
interface ByBiller {
  billerLabel: string;
  byCurrency:  ByCurrency;
  orderCount:  number;
}
interface RevenueData {
  kpis:       KPIs;
  byNetwork:  ByNetwork[];
  byProduct:  ByProduct[];
  byBiller:   ByBiller[];
}

type Preset = '7d' | '30d' | '90d' | 'ytd' | 'all';

const PRESETS: { label: string; value: Preset }[] = [
  { label: '7D',  value: '7d'  },
  { label: '30D', value: '30d' },
  { label: '90D', value: '90d' },
  { label: 'YTD', value: 'ytd' },
  { label: 'All', value: 'all' },
];

function fmtMulti(byCurrency: ByCurrency = {}): string {
  const entries = Object.entries(byCurrency);
  if (!entries.length) return '—';
  return entries.map(([cur, amt]) =>
    `${(amt / 100).toLocaleString('en-US', { minimumFractionDigits: 2 })} ${cur.toUpperCase()}`
  ).join(' · ');
}

function KpiCard({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.kpi}>
      <Text style={styles.kpiLabel}>{label}</Text>
      <Text style={styles.kpiValue}>{value}</Text>
    </View>
  );
}

type Tab = 'networks' | 'products' | 'billers';

export default function PlatformRevenueScreen() {
  const router = useRouter();
  const [preset,   setPreset]   = useState<Preset>('30d');
  const [data,     setData]     = useState<RevenueData | null>(null);
  const [loading,  setLoading]  = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [tab,      setTab]      = useState<Tab>('networks');
  const abortRef = useRef<AbortController | null>(null);

  const load = useCallback(async (p: Preset) => {
    abortRef.current?.abort();
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    try {
      const d = await apiGet<RevenueData>(`/api/admin/revenue?preset=${p}`);
      setData(d);
    } catch {
      //
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => { load(preset); }, [preset, load]);

  return (
    <Screen>
      <TouchableOpacity onPress={() => router.back()} style={styles.back}>
        <Text style={styles.backTxt}>← Platform Revenue</Text>
      </TouchableOpacity>

      {/* Preset picker */}
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.presets} contentContainerStyle={styles.presetsInner}>
        {PRESETS.map(p => (
          <TouchableOpacity
            key={p.value}
            style={[styles.presetChip, preset === p.value && styles.presetActive]}
            onPress={() => { setLoading(true); setPreset(p.value); }}
          >
            <Text style={[styles.presetTxt, preset === p.value && styles.presetTxtActive]}>
              {p.label}
            </Text>
          </TouchableOpacity>
        ))}
      </ScrollView>

      {loading ? (
        <View style={styles.center}><ActivityIndicator color={C.watch} /></View>
      ) : (
        <ScrollView
          contentContainerStyle={styles.scroll}
          refreshControl={
            <RefreshControl
              refreshing={refreshing}
              onRefresh={() => { setRefreshing(true); load(preset); }}
              tintColor={C.watch}
            />
          }
        >
          {/* KPIs */}
          <View style={styles.kpiGrid}>
            <KpiCard label="Total Revenue"  value={fmtMulti(data?.kpis.totalRevenue)} />
            <KpiCard label="MRR"            value={fmtMulti(data?.kpis.mrr)} />
            <KpiCard label="Platform Share" value={fmtMulti(data?.kpis.platformShare)} />
            <KpiCard label="Total Orders"   value={String(data?.kpis.totalOrders ?? 0)} />
            <KpiCard label="Active Subs"    value={String(data?.kpis.activeSubscribers ?? 0)} />
          </View>

          {/* Tab row */}
          <View style={styles.tabRow}>
            {(['networks', 'products', 'billers'] as Tab[]).map(t => (
              <TouchableOpacity
                key={t}
                style={[styles.tabBtn, tab === t && styles.tabActive]}
                onPress={() => setTab(t)}
              >
                <Text style={[styles.tabTxt, tab === t && styles.tabTxtActive]}>
                  {t.charAt(0).toUpperCase() + t.slice(1)}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          {/* Networks */}
          {tab === 'networks' && (data?.byNetwork ?? []).map(n => (
            <View key={n.networkId} style={styles.row}>
              <View style={{ flex: 1 }}>
                <Text style={styles.rowMain}>{n.networkName}</Text>
                <Text style={styles.rowSub}>{n.orderCount} orders</Text>
              </View>
              <Text style={styles.rowAmt}>{fmtMulti(n.byCurrency)}</Text>
            </View>
          ))}

          {/* Products */}
          {tab === 'products' && (data?.byProduct ?? []).map(p => (
            <View key={p.productId} style={styles.row}>
              <View style={{ flex: 1 }}>
                <Text style={styles.rowMain}>{p.productName}</Text>
                <Text style={styles.rowSub}>{p.networkName} · {p.type} · {p.orderCount} orders</Text>
              </View>
              <Text style={styles.rowAmt}>{fmtMulti(p.byCurrency)}</Text>
            </View>
          ))}

          {/* Billers */}
          {tab === 'billers' && (data?.byBiller ?? []).map(b => (
            <View key={b.billerLabel} style={styles.row}>
              <View style={{ flex: 1 }}>
                <Text style={styles.rowMain}>{b.billerLabel}</Text>
                <Text style={styles.rowSub}>{b.orderCount} orders</Text>
              </View>
              <Text style={styles.rowAmt}>{fmtMulti(b.byCurrency)}</Text>
            </View>
          ))}

          {!data && (
            <View style={styles.empty}>
              <Text style={styles.emptyTxt}>No revenue data.</Text>
            </View>
          )}
        </ScrollView>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  back:    { padding: 16, paddingBottom: 0 },
  backTxt: { color: C.textSub, fontSize: 14 },
  center:  { flex: 1, alignItems: 'center', justifyContent: 'center' },

  presets:      { maxHeight: 56, paddingTop: 12 },
  presetsInner: { paddingHorizontal: 16, gap: 8, flexDirection: 'row' },
  presetChip:   {
    paddingHorizontal: 14, paddingVertical: 7,
    borderRadius: 20, borderWidth: 1, borderColor: C.border,
    backgroundColor: C.surface2,
  },
  presetActive: { borderColor: C.watch, backgroundColor: `${C.watch}20` },
  presetTxt:    { fontSize: 12, fontWeight: '600', color: C.textMuted },
  presetTxtActive: { color: C.watch },

  scroll: { padding: 20, paddingBottom: 60 },

  kpiGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10, marginBottom: 24 },
  kpi: {
    minWidth: 140, flex: 1,
    backgroundColor: C.surface2, borderRadius: 14,
    borderWidth: 1, borderColor: C.border,
    padding: 14,
  },
  kpiLabel: { fontSize: 10, fontWeight: '700', color: C.textMuted, textTransform: 'uppercase', letterSpacing: 0.8 },
  kpiValue: { fontSize: 18, fontWeight: '800', color: C.text, marginTop: 4 },

  tabRow: { flexDirection: 'row', gap: 6, marginBottom: 14 },
  tabBtn: {
    flex: 1, paddingVertical: 9, borderRadius: 10, alignItems: 'center',
    backgroundColor: C.surface2, borderWidth: 1, borderColor: C.border,
  },
  tabActive:   { borderColor: C.watch, backgroundColor: `${C.watch}20` },
  tabTxt:      { fontSize: 12, fontWeight: '600', color: C.textMuted },
  tabTxtActive:{ color: C.watch },

  row: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: C.surface2, borderRadius: 12,
    borderWidth: 1, borderColor: C.border,
    padding: 12, marginBottom: 6, gap: 8,
  },
  rowMain: { fontSize: 13, fontWeight: '600', color: C.text },
  rowSub:  { fontSize: 11, color: C.textMuted, marginTop: 2 },
  rowAmt:  { fontSize: 13, fontWeight: '700', color: C.text },

  empty:    { alignItems: 'center', paddingTop: 60 },
  emptyTxt: { color: C.textMuted, fontSize: 13 },
});
