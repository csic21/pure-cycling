import {
  cleanupAccount,
  type CleanupDeps,
  CleanupError,
  jsonResponse,
  verifiedUserId,
} from '../_shared/account-cleanup.ts';

export async function handleWipeCloudData(
  req: Request,
  deps: CleanupDeps,
): Promise<Response> {
  if (req.method !== 'POST') return jsonResponse({ error: '只接受 POST' }, 405);
  const userId = await verifiedUserId(req, deps);
  if (!userId) {
    return jsonResponse({ error: '需要登录后才能清理云端数据' }, 401);
  }
  try {
    const files = await cleanupAccount(userId, userId, 'wipe', deps);
    return jsonResponse({ wiped: true, files });
  } catch (error) {
    const failure = error instanceof CleanupError
      ? error
      : new CleanupError(502, '清理云端数据失败，请稍后重试');
    return jsonResponse({ error: failure.message }, failure.status);
  }
}
