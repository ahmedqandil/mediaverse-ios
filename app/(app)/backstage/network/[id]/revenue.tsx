/**
 * Network revenue screen — mirrors web AdminRevenueClient.tsx (network-scoped).
 * Pulls from /api/backstage/network/[id]/billing/summary and
 * /api/backstage/network/[id]/billing/revenue-by-product
 * Permission-gated: view_analytics
 */
import { useCallback, useEffect, useState } from 'react';
import {
  ScrollView, View, Text, TouchableOpacity,
  ActivityIndicator, StyleSheet, RefreshControl,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { Screen } from '@/components/ui/Screen';
import { apiGet } from '@/lib/api';
import { C } from '@/lib/constants';

type ByCurrency = Record<string, number>;

interface BillingSummary {
  activeSubscribers: number;
  pastDue:           number;
  mrrByCurrency:     ByCurrency;
  ppvByCurrency:     ByCurrency;
  recentOrders: Array<{
    id:        string;
    type:      string;
    status:    string;
    currency:  string;
    amount:    number;
    createdAt: string;
    user?:     { name: string | null; email: string | null };
    product?:  { name: string };
  }>;
}

interface ProductRevenue {
  productId:   string;
  productName: string;
  type:        string;
  byCurrency:  ByCurrency;
  orderCount:  number;
}

function fmtMulti(byCurrency: ByCurrency): string {
  const entries = Object.entries(byCurrency);
  if (!entries.length) return '—';
  return entries.map(([cur, amt]) =>
    `${(amt / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ${cur.toUpperCase()}`
  ).join(' · ');
}

function KpiCard({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <View style={styles.kpi}>
      <Text style={styles.kpiLabel}>{label}</Text>
      <Text style={styles.kpiValue}>{value}</Text>
      {sub && <Text style={styles.kpiSub}>{sub}</Text>}
    </View>
  );
}

export default function NetworkRevenueScreen() {
  const { id: networkId } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();

  const [summary,   setSummary]   = useState<BillingSummary | null>(null);
  const [products,  setProducts]  = useState<ProductRevenue[]>([]);
  const [loading,   setLoading]   = useState(true);
  const [refreshing,setRefreshing]= useState(false);

  const load = useCallback(async () => {
    try {
      const [s, p] = await Promise.all([
        apiGet<BillingSummary>(`/api/backstage/network/${networkId}/billing/summary`),
        apiGet<{ products: ProductRevenue[] }>(`/api/backstage/network/${networkId}/billing/revenue-by-product`)
          .then(d => d.products ?? []).catch(() => []),
      ]);
      setSummary(s);
      setProducts(p);
    } catch {
      //
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [networkId]);

  useEffect(() => { load(); }, [load]);

  if (loading) {
    return <Screen style={styles.center}><ActivityIndicator color={C.watch} /></Screen>;
  }

  return (
    <Screen>
      <TouchableOpacity onPress={() => router.back()} style={styles.back}>
        <Text style={styles.backTxt}>← Revenue</Text>
      </TouchableOpacity>

      <ScrollView
        contentContainerStyle={styles.scroll}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={() => { setRefreshing(true); load(); }}
            tintColor={C.watch}
          />
        }
      >
        {/* KPI grid */}
        <View style={styles.kpiGrid}>
          <KpiCard
            label="Active Subs"
            value={String(summary?.activeSubscribers ?? 0)}
            sub={summary?.pastDue ? `${summary.pastDue} past due` : undefined}
          />
          <KpiCard
            label="MRR"
            value={fmtMulti(summary?.mrrByCurrency ?? {})}
          />
          <KpiCard
            label="PPV Revenue"
            value={fmtMulti(summary?.ppvByCurrency ?? {})}
          />
        </View>

        {/* By Product */}
        {products.length > 0 && (
          <>
            <Text style={styles.sectionLabel}>By Product</Text>
            {products.map(p => (
              <View key={p.productId} style={styles.tableRow}>
                <View style={{ flex: 1 }}>
                  <Text style={styles.tableMain}>{p.productName}</Text>
                  <Text style={styles.tableSub}>{p.type} · {p.orderCount} orders</Text>
                </View>
                <Text style={styles.tableAmt}>{fmtMulti(p.byCurrency)}</Text>
              </View>
            ))}
          </>
        )}

        {/* Recent orders */}
        {(summary?.recentOrders?.length ?? 0) > 0 && (
          <>
            <Text style={styles.sectionLabel}>Recent Orders</Text>
            {summary!.recentOrders.map(o => (
              <View key={o.id} style={styles.tableRow}>
                <View style={{ flex: 1 }}>
                  <Text style={styles.tableMain}>{o.user?.name ?? o.user?.email ?? 'Unknown'}</Text>
                  <Text style={styles.tableSub}>{o.product?.name ?? o.type}</Text>
                </View>
                <View style={{ alignItems: 'flex-end' }}>
                  <Text style={styles.tableAmt}>
                    {(o.amount / 100).toFixed(2)} {o.currency.toUpperCase()}
                  </Text>
                  <Text style={[styles.orderStatus, {
                    color: o.status === 'PAID' ? C.watch : o.status === 'PENDING' ? C.amber : C.danger,
                  }]}>
                    {o.status.toLowerCase()}
                  </Text>
                </View>
              </View>
            ))}
          </>
        )}

        {!summary && (
          <View style={styles.empty}>
            <Text style={styles.emptyTxt}>No revenue data available.</Text>
          </View>
        )}
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  center:  { flex: 1, alignItems: 'center', justifyContent: 'center' },
  back:    { padding: 16, paddingBottom: 0 },
  backTxt: { color: C.textSub, fontSize: 14 },
  scroll:  { padding: 20, paddingBottom: 60 },

  kpiGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  kpi: {
    flex: 1, minWidth: 140,
    backgroundColor: C.surface2, borderRadius: 14,
    borderWidth: 1, borderColor: C.border,
    padding: 14,
  },
  kpiLabel: { fontSize: 10, fontWeight: '700', color: C.textMuted, textTransform: 'uppercase', letterSpacing: 0.8 },
  kpiValue: { fontSize: 20, fontWeight: '800', color: C.text, marginTop: 4 },
  kpiSub:   { fontSize: 11, color: C.danger, marginTop: 2 },

  sectionLabel: {
    fontSize: 10, fontWeight: '800', color: C.textMuted,
    textTransform: 'uppercase', letterSpacing: 1.2,
    marginTop: 24, marginBottom: 10, paddingHorizontal: 2,
  },

  tableRow: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: C.surface2, borderRadius: 12,
    borderWidth: 1, borderColor: C.border,
    padding: 12, marginBottom: 6, gap: 8,
  },
  tableMain: { fontSize: 13, fontWeight: '600', color: C.text },
  tableSub:  { fontSize: 11, color: C.textMuted, marginTop: 2 },
  tableAmt:  { fontSize: 13, fontWeight: '700', color: C.text },
  orderStatus: { fontSize: 10, fontWeight: '700', textTransform: 'uppercase', marginTop: 2 },

  empty:    { alignItems: 'center', paddingTop: 60 },
  emptyTxt: { color: C.textMuted, fontSize: 13 },
});
