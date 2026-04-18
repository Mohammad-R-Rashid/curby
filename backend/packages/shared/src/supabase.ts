// ============================================================
// Supabase Client Factory
// ============================================================

import { createClient, SupabaseClient } from '@supabase/supabase-js';

/**
 * Creates a new Supabase client per invocation.
 *
 * In Cloudflare Workers, module-level singletons are WRONG —
 * each worker invocation may get different env secrets,
 * and DO instances have their own env. A singleton could
 * cache the wrong credentials if secrets rotate.
 *
 * The Supabase client is lightweight, so creating per-request
 * is fine for Workers' execution model.
 */
export function getSupabase(url: string, secretKey: string): SupabaseClient {
  return createClient(url, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
