'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';

import { createAdminClient } from '@/lib/supabase/admin';
import { createClient } from '@/lib/supabase/server';

/// Where to send the operator after an action.
///
/// The list can be filtered and paged, and an action that throws the operator
/// back to page one of an unfiltered list makes them find the row again — on a
/// thousand accounts, that is the difference between a tool and a chore. The
/// filter travels in hidden fields on the action forms.
function backToList(formData: FormData, extra: { error?: string } = {}): string {
  const params = new URLSearchParams();
  const search = String(formData.get('q') ?? '').trim();
  const page = Number.parseInt(String(formData.get('page') ?? '1'), 10) || 1;
  if (search) params.set('q', search);
  if (page > 1) params.set('page', String(page));
  if (extra.error) params.set('error', extra.error);
  const query = params.toString();
  return query ? `/users?${query}` : '/users';
}

/// Shared guard: who is asking, and may they act on this account?
async function requireActingAdmin(targetUserId: string, formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: isAdmin } = await supabase.rpc('is_admin');
  if (isAdmin !== true) {
    redirect(backToList(formData, { error: '当前账号不是管理员' }));
  }
  if (targetUserId === user.id) {
    redirect(backToList(formData, { error: '不能对自己执行这个操作' }));
  }
  return user;
}

/**
 * Bans or unbans an account.
 *
 * Two credentials are used on purpose. The caller's own session answers *who
 * is asking* — `is_admin()` is evaluated by the database through RLS — and
 * the service role performs the ban, which GoTrue only accepts with that key.
 * Neither check is redundant: the first cannot ban, the second cannot tell
 * who is calling.
 */
export async function setUserDisabled(formData: FormData) {
  const userId = String(formData.get('userId') ?? '');
  const disabled = formData.get('disabled') === 'true';

  const user = await requireActingAdmin(userId, formData);

  const admin = createAdminClient();
  const { error } = await admin.auth.admin.updateUserById(userId, {
    // GoTrue takes a duration string; `none` lifts an existing ban.
    ban_duration: disabled ? '876000h' : 'none',
  });
  if (error) {
    redirect(backToList(formData, { error: error.message }));
  }

  // Appended after the action succeeded. The console's 「已封禁」 badge is
  // derived from the latest of these rows, so a failed ban must not appear.
  await admin.from('admin_audit').insert({
    admin_id: user.id,
    action: disabled ? 'disable_user' : 'enable_user',
    target_user_id: userId,
  });

  revalidatePath('/users');
  revalidatePath('/audit');
  redirect('/users');
}

/**
 * Deletes an account and everything it owns.
 *
 * The storage step is the one that is easy to forget. `auth.users` owns the
 * rows through foreign keys, so deleting the user cascades rides and routes
 * away — but **nothing cascades into Storage**. Skip the objects and the GPX
 * files stay in the bucket forever, owned by a user id that no longer exists:
 * a location trace that nobody can see, nobody can delete, and that still
 * counts against the project's storage quota.
 *
 * Order matters for the same reason as the app's own wipe: objects first, the
 * user last.
 */
export async function deleteUser(formData: FormData) {
  const userId = String(formData.get('userId') ?? '');
  const user = await requireActingAdmin(userId, formData);

  const admin = createAdminClient();

  // 1. The object paths, read before the rows that index them disappear.
  const { data: rides } = await admin
    .from('rides')
    .select('gpx_path')
    .eq('user_id', userId)
    .not('gpx_path', 'is', null);
  const paths = (rides ?? [])
    .map((row) => row.gpx_path as string | null)
    .filter((path): path is string => typeof path === 'string');

  // 2. Objects, in chunks — the Storage API takes a list per call.
  let removedFiles = 0;
  for (let i = 0; i < paths.length; i += 100) {
    const slice = paths.slice(i, i + 100);
    try {
      await admin.storage.from('rides').remove(slice);
      removedFiles += slice.length;
    } catch {
      // A missing object is not a failure; the goal state is "absent".
    }
  }

  // 3. The account. Rows follow by cascade.
  const { error } = await admin.auth.admin.deleteUser(userId);
  if (error) {
    redirect(backToList(formData, { error: error.message }));
  }

  await admin.from('admin_audit').insert({
    admin_id: user.id,
    action: 'delete_user',
    target_user_id: userId,
    detail: { files: removedFiles },
  });

  revalidatePath('/users');
  revalidatePath('/audit');
  redirect('/users');
}
