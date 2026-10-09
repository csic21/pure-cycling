import {
  cleanupAccount,
  type CleanupDeps,
  type CleanupEnv,
  CleanupError,
  type FetchLike,
  jsonResponse,
  verifiedUserId,
} from '../_shared/account-cleanup.ts';
export type { FetchLike };
export type DeleteEnv = CleanupEnv;
export type DeleteDeps = CleanupDeps;

// The actor and target are ALWAYS the verified caller, never a request field.
export async function handleDeleteAccount(
  req: Request,
  deps: DeleteDeps,
): Promise<Response> {
  if (req.method !== 'POST') return jsonResponse({ error: '只接受 POST' }, 405);
  const userId = await verifiedUserId(req, deps);
  if (!userId) return jsonResponse({ error: '需要登录后才能删除账号' }, 401);
  try {
    const files = await cleanupAccount(userId, userId, 'delete', deps);
    return jsonResponse({ deleted: true, files });
  } catch (error) {
    const failure = error instanceof CleanupError
      ? error
      : new CleanupError(502, '删除账号失败，请稍后重试');
    return jsonResponse({ error: failure.message }, failure.status);
  }
}
