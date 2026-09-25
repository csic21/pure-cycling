// The routing relay: the AMap key never leaves the server.
//
// The logic lives in `handler.ts` (injected dependencies, testable without a
// network); this file is the Deno wiring. The key lives in this function's
// environment — not in the app, because anything a client sends, the device
// owner can read.
//
// Deploy:
//   supabase functions deploy route
//   supabase secrets set AMAP_KEY=...
//
// Local:
//   supabase functions serve --env-file supabase/functions/.env.local
//
// Verified by scripts/verify-routing-relay.sh (real runtime, stub vendor) and
// by handler_test.ts (logic, `deno test`, no Docker).

import { handleRoute } from './handler.ts';

Deno.serve((req) =>
  handleRoute(req, {
    fetch: fetch,
    env: {
      supabaseUrl: Deno.env.get('SUPABASE_URL') ?? '',
      anonKey: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      amapKey: Deno.env.get('AMAP_KEY') ?? '',
      // Overridable so the verification script can point it at a stub instead
      // of the vendor. Production never sets it.
      amapBase: Deno.env.get('AMAP_BASE_URL') ?? 'https://restapi.amap.com',
      // Per account, per day. The project's own free quota is 150,000
      // calls/month for route planning; this keeps one account from being the
      // reason it runs out.
      dailyLimit: Number(Deno.env.get('ROUTE_DAILY_LIMIT') ?? '200'),
    },
  }));
