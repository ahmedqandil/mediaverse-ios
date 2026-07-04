// ─── Auth ─────────────────────────────────────────────────────────────────────
export interface SessionUser {
  id:    string;
  email: string;
  name:  string | null;
  image: string | null;
  role:  string;
}

// ─── Active context (mirrors web mv_active_ctx cookie shape) ──────────────────
export interface ActiveContext {
  type:                'admin' | 'network' | 'channel';
  id:                  string;
  name:                string;
  channelId:           string | null;
  damEnabled:          boolean;
  canCreateShows:      boolean;
  canPublishMicrodramas: boolean;
}

// ─── Content ──────────────────────────────────────────────────────────────────
export type AccessState = 'free' | 'locked' | 'subscribed' | 'rented';

export interface VideoItem {
  id:           string;
  title:        string;
  description?: string;
  thumbnailUrl: string | null;
  videoUrl:     string | null;
  duration?:    number;
  viewCount?:   number;
  likeCount?:   number;
  accessState?: AccessState;
  channel?: {
    id:     string;
    name:   string;
    handle: string;
    avatarUrl: string | null;
  };
}

export interface EpisodeItem {
  id:            string;
  title:         string;
  episodeNumber: number;
  thumbnailUrl:  string | null;
  videoUrl:      string | null;
  duration?:     number;
  accessState?:  AccessState;
  commentCount?: number;
}

export interface ShowItem {
  id:           string;
  title:        string;
  description?: string;
  thumbnailUrl: string | null;
  episodeCount: number;
  network?: { id: string; name: string };
}

// ─── Network / Backstage ──────────────────────────────────────────────────────
export interface NetworkMember {
  id:        string;
  userId:    string;
  email:     string;
  name:      string | null;
  role:      string;
  createdAt: string;
}

export interface NetworkDetail {
  id:           string;
  name:         string;
  description?: string;
  logoUrl?:     string | null;
  memberCount:  number;
  channelCount: number;
  showCount:    number;
}

// ─── Revenue ──────────────────────────────────────────────────────────────────
export type ByCurrency = Record<string, number>;

export interface RevenueKPIs {
  totalByCurrency:           ByCurrency;
  mrrByCurrency:             ByCurrency;
  totalOrders:               number;
  activeSubscribers:         number;
  platformRevenueByCurrency: ByCurrency;
}

export interface RevenueByNetwork {
  networkId:       string;
  name:            string;
  orderCount:      number;
  revenueByCurrency: ByCurrency;
  platformSharePct:  number;
}

export interface RevenueByProduct {
  productId:       string;
  name:            string;
  type:            string;
  networkName:     string;
  orderCount:      number;
  revenueByCurrency: ByCurrency;
}

export interface RevenueByBiller {
  biller:          string;
  orderCount:      number;
  revenueByCurrency: ByCurrency;
}

export interface TimeSeries {
  date:            string;
  revenueByCurrency: ByCurrency;
}

export interface RevenueData {
  kpis:       RevenueKPIs;
  byNetwork:  RevenueByNetwork[];
  byProduct:  RevenueByProduct[];
  byBiller:   RevenueByBiller[];
  timeSeries: TimeSeries[];
}
