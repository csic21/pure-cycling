// Self-service account deletion.
//
// The logic lives in `handler.ts` (injected dependencies, testable without a
// network); this file is the Deno wiring.
//
// Deploy:
//   supabase functions deploy delete-account
//
// No extra secrets: SUPABASE_URL / ANON_KEY / SERVICE_ROLE_KEY are injected by
// the platform. The service key is what makes this possible at all — GoTrue
// only lets the service role delete a user, and that key must never reach a
// client.
//
// Verified by scripts/verify-account-deletion.sh (real runtime, real session,
// real Storage) and by handler_test.ts (`deno test`, no Docker).

import { handleDeleteAccount } from './handler.ts';

Deno.serve((req) =>
  handleDeleteAccount(req, {
    fetch: fetch,
    env: {
      supabaseUrl: Deno.env.get('SUPABASE_URL') ?? '',
      anonKey: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    },
  }));
