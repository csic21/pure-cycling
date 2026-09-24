import 'server-only';

import { createClient } from '@supabase/supabase-js';

/**
 * The service-role client. Bypasses RLS entirely.
 *
 * `server-only` turns an accidental import from a client component into a
 * build error, which is the only reliable way to keep this key out of a
 * browser bundle. Import it inside server actions only.
 */
export function createAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    throw new Error(
      'NEXT_PUBLIC_SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 未配置（见 .env.example）',
    );
  }

  return createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
