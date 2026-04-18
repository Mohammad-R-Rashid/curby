// ============================================================
// RegionCoordinatorDO — Types
// ============================================================

import type { LatLng } from '@curby/shared';

export interface DOSession {
  ws: WebSocket;
  userId: string;
  /** User's actual GPS location when they connected */
  userLocation: LatLng;
  /** Where the user wants to park near */
  destination: LatLng;
  recommendedArea?: string;
  sessionId?: string;
  status: 'searching' | 'routing' | 'arrived';
}
