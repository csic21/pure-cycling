/** Shared by the self-service functions and the admin server action.
 * Storage, not ride rows, is the index: uploads can outlive a failed push_ride.
 * The database fences user writes before listing and checks emptiness again
 * before clearing rows. All deletions still go through the Storage API.
 */
export type FetchLike = typeof globalThis.fetch;
export interface CleanupEnv {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
}
export interface CleanupDeps {
  fetch: FetchLike;
  env: CleanupEnv;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function isUserId(value: unknown): value is string {
  return typeof value === 'string' && uuid.test(value);
}

export class CleanupError extends Error {
  constructor(public readonly status: number, message: string) {
    super(message);
  }
}

export async function verifiedUserId(
  req: Request,
  { fetch, env }: CleanupDeps,
): Promise<string | null> {
  const authorization = req.headers.get('Authorization') ?? '';
  if (!authorization.startsWith('Bearer ') || !env.supabaseUrl) return null;
  try {
    const response = await fetch(`${env.supabaseUrl}/auth/v1/user`, {
      headers: { apikey: env.anonKey, Authorization: authorization },
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) return null;
    const user = await response.json();
    return isUserId(user?.id) ? user.id : null;
  } catch {
    return null;
  }
}

export function serviceHeaders(env: CleanupEnv): Record<string, string> {
  return { apikey: env.serviceKey, Authorization: `Bearer ${env.serviceKey}` };
}

export async function cleanupAccount(
  userId: string,
  actorId: string,
  mode: 'wipe' | 'delete',
  { fetch, env }: CleanupDeps,
): Promise<number> {
  if (!isUserId(userId) || !isUserId(actorId)) {
    throw new CleanupError(400, '账号 ID 无效');
  }
  if (!env.serviceKey) throw new CleanupError(503, '服务端没有配置清理权限');
  const token = crypto.randomUUID();
  const parameters = { p_user_id: userId, p_token: token };
  const headers = {
    ...serviceHeaders(env),
    'Content-Type': 'application/json',
  };
  const rpc = async (name: string, body: Record<string, unknown>) => {
    const response = await fetch(`${env.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) {
      const error = await response.json().catch(() => ({}));
      if (error?.code === '55P03') {
        throw new CleanupError(409, '云端清理正在进行，请稍后重试');
      }
      throw new CleanupError(502, '云端清理尚未完成，请稍后重试');
    }
    return response;
  };

  let claimed = false;
  try {
    await rpc('begin_account_cleanup', {
      ...parameters,
      p_actor_id: actorId,
      p_mode: mode,
    });
    claimed = true;
    const prefix = `rides/${userId}/`;
    let files = 0;
    let previousPaths = new Set<string>();
    // Stay inside the function runtime budget. A partial run keeps its fence
    // and is resumable; it must never masquerade as a completed wipe.
    const deadline = Date.now() + 240_000;
    for (;;) {
      if (Date.now() >= deadline) {
        throw new CleanupError(502, '云端数据较多，清理尚未完成，请重试以继续');
      }
      const response = await rpc('list_account_cleanup_objects', parameters);
      const rows = await response.json();
      if (!Array.isArray(rows)) throw new Error('invalid object list');
      if (rows.length === 0) break;
      const paths: string[] = rows.map((row) => {
        const path = row?.name;
        if (
          typeof path !== 'string' || !path.startsWith(prefix) ||
          path.length <= prefix.length ||
          path.split('/').some((part: string) =>
            part === '.' || part === '..' || part === ''
          )
        ) {
          throw new Error('object outside verified account prefix');
        }
        return path;
      });
      if (paths.some((path) => previousPaths.has(path))) {
        throw new Error('storage deletion made no progress');
      }
      previousPaths = new Set(paths);
      for (let i = 0; i < paths.length; i += 100) {
        const slice = paths.slice(i, i + 100);
        const removed = await fetch(
          `${env.supabaseUrl}/storage/v1/object/rides`,
          {
            method: 'DELETE',
            headers,
            body: JSON.stringify({ prefixes: slice }),
            signal: AbortSignal.timeout(30_000),
          },
        );
        if (!removed.ok) throw new Error('storage removal failed');
        files += slice.length;
      }
      // Always drain page zero. Offsets after deletion would skip objects.
    }
    await rpc('finish_account_cleanup', parameters);
    if (mode === 'delete') {
      const removed = await fetch(
        `${env.supabaseUrl}/auth/v1/admin/users/${userId}`,
        {
          method: 'DELETE',
          headers: serviceHeaders(env),
          signal: AbortSignal.timeout(30_000),
        },
      );
      if (!removed.ok && removed.status !== 404) {
        throw new CleanupError(502, '云端文件已清理，但账号尚未删除，请重试');
      }
    }
    return files;
  } catch (error) {
    if (claimed) {
      // Only the worker lease is released, NEVER the durable write fence.
      // If this best-effort call fails, a retry takes over after lease expiry.
      await rpc('release_account_cleanup', parameters).catch(() => {});
    }
    if (error instanceof CleanupError) throw error;
    throw new CleanupError(502, '清理云端数据失败，尚未完成，请稍后重试');
  }
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}
