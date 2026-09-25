// Self-service account deletion, with everything external injected.
//
// `index.ts` is the Deno wiring around this; the logic lives here so it runs
// under `deno test` without a runtime or a network. The real thing (a served
// function, a real session, real Storage) is driven by
// `scripts/verify-account-deletion.sh`.
//
// ## Why this has to be server-side
//
// Deleting an account means deleting the `auth.users` row, and GoTrue only
// allows that with the service role — which must never reach a client. So the
// app asks this function, and the function uses its own credentials.
//
// ## The order is not negotiable
//
// Objects first, then the account. `auth.users` owns rows through foreign
// keys, so deleting the user cascades rides, routes and settings away — but
// **nothing cascades into Storage**. Skip the first step and the GPX files
// stay in the bucket forever, owned by a user id that no longer exists: a
// location trace nobody can see, nobody can delete, and that still counts
// against the project's quota.
//
// ## Whose account
//
// The caller's own, always. The identity comes from the session; there is no
// parameter that names a user, so this endpoint cannot be pointed at somebody
// else. Operator-initiated deletion is a different surface entirely (the admin
// console's server actions, audited).

export type FetchLike = typeof globalThis.fetch;

export interface DeleteEnv {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
}

export interface DeleteDeps {
  fetch: FetchLike;
  env: DeleteEnv;
}

export async function handleDeleteAccount(
  req: Request,
  { fetch, env }: DeleteDeps,
): Promise<Response> {
  if (req.method !== 'POST') {
    return failure(405, '只接受 POST');
  }

  const userId = await verifiedUserId(req, fetch, env);
  if (userId === null) {
    return failure(401, '需要登录后才能删除账号');
  }

  if (env.serviceKey === '') {
    return failure(503, '服务端没有配置删除权限');
  }

  // 1. The GPX paths, read before the rows that index them are gone.
  const paths = await listGpxPaths(userId, fetch, env);
  const files = await deleteObjects(paths, fetch, env);

  // 2. The account. Rows follow by cascade; the objects are already gone.
  if (!(await deleteUser(userId, fetch, env))) {
    return failure(502, '删除账号失败，请稍后再试');
  }

  return new Response(JSON.stringify({ deleted: true, files }), {
    status: 200,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}

/// Resolves the caller through the auth server, or null.
///
/// The platform verifies the JWT signature before this runs (`verify_jwt` is
/// on for this function), but identity is what the whole operation hangs on,
/// so it is confirmed with the auth server rather than inferred.
async function verifiedUserId(
  req: Request,
  fetch: FetchLike,
  env: DeleteEnv,
): Promise<string | null> {
  const authorization = req.headers.get('Authorization') ?? '';
  if (!authorization.startsWith('Bearer ') || env.supabaseUrl === '') {
    return null;
  }

  try {
    const response = await fetch(`${env.supabaseUrl}/auth/v1/user`, {
      headers: { apikey: env.anonKey, Authorization: authorization },
    });
    if (!response.ok) return null;
    const user = await response.json();
    return typeof user?.id === 'string' ? user.id : null;
  } catch {
    return null;
  }
}

/// Every GPX object this account references.
async function listGpxPaths(
  userId: string,
  fetch: FetchLike,
  env: DeleteEnv,
): Promise<string[]> {
  try {
    const url = new URL(`${env.supabaseUrl}/rest/v1/rides`);
    url.searchParams.set('select', 'gpx_path');
    url.searchParams.set('user_id', `eq.${userId}`);
    url.searchParams.set('gpx_path', 'not.is.null');

    const response = await fetch(url, { headers: serviceHeaders(env) });
    if (!response.ok) return [];
    const rows = await response.json();
    if (!Array.isArray(rows)) return [];
    return rows
      .map((row) => row?.gpx_path)
      .filter((path): path is string => typeof path === 'string');
  } catch {
    return [];
  }
}

/// Removes objects, in chunks. A missing object is not a failure — the goal
/// state is "absent" — but a chunk that errors is counted as not removed.
async function deleteObjects(
  paths: string[],
  fetch: FetchLike,
  env: DeleteEnv,
): Promise<number> {
  let removed = 0;
  const chunk = 100;

  for (let i = 0; i < paths.length; i += chunk) {
    const slice = paths.slice(i, i + chunk);
    try {
      const response = await fetch(
        `${env.supabaseUrl}/storage/v1/object/rides`,
        {
          method: 'DELETE',
          headers: {
            ...serviceHeaders(env),
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ prefixes: slice }),
        },
      );
      if (response.ok) removed += slice.length;
    } catch {
      // Keep going; the rest of the list still has to go.
    }
  }

  return removed;
}

async function deleteUser(
  userId: string,
  fetch: FetchLike,
  env: DeleteEnv,
): Promise<boolean> {
  try {
    const response = await fetch(
      `${env.supabaseUrl}/auth/v1/admin/users/${userId}`,
      { method: 'DELETE', headers: serviceHeaders(env) },
    );
    return response.ok;
  } catch {
    return false;
  }
}

function serviceHeaders(env: DeleteEnv): Record<string, string> {
  return {
    apikey: env.serviceKey,
    Authorization: `Bearer ${env.serviceKey}`,
  };
}

function failure(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}
