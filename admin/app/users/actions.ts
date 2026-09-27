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

  // Server Actions are callable without visiting the page. The page hides
  // admin targets, but that UI check must also live at this boundary.
  const admin = createAdminClient();
  const { data: targetAdmin, error: membershipError } = await admin
    .from('admins')
    .select('user_id')
    .eq('user_id', targetUserId)
    .maybeSingle();
  if (membershipError) {
    redirect(backToList(formData, { error: '无法核实目标账号权限，请稍后重试' }));
  }
  if (targetAdmin) {
    redirect(backToList(formData, { error: '不能对管理员账号执行这个操作' }));
  }
  return { user, admin };
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

  const { user, admin } = await requireActingAdmin(userId, formData);
  const { error } = await admin.auth.admin.updateUserById(userId, {
    // GoTrue takes a duration string; `none` lifts an existing ban.
    ban_duration: disabled ? '876000h' : 'none',
  });
  if (error) {
    redirect(backToList(formData, { error: error.message }));
  }

  // Appended after the action succeeded. The console's 「已封禁」 badge is
  // derived from the latest of these rows, so a failed ban must not appear.
  const { error: auditError } = await admin.from('admin_audit').insert({
    admin_id: user.id,
    action: disabled ? 'disable_user' : 'enable_user',
    target_user_id: userId,
  });
  if (auditError) {
    redirect(backToList(formData, { error: '封禁状态已更改，但审计日志写入失败，请检查后台' }));
  }

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
  const { user, admin } = await requireActingAdmin(userId, formData);

  // 1. The object paths, read before the rows that index them disappear.
  const paths: string[] = [];
  for (let offset = 0; ; offset += 500) {
    const { data: rides, error: listError } = await admin
      .from('rides')
      .select('id, gpx_path')
      .eq('user_id', userId)
      .not('gpx_path', 'is', null)
      .order('id')
      .range(offset, offset + 499);
    if (listError) {
      redirect(backToList(formData, { error: '读取轨迹文件失败，账号未删除，请稍后重试' }));
    }
    for (const ride of rides ?? []) {
      // A rider can supply gpx_path through sync. Never let a forged ride row
      // point the service-role delete at someone else's private object.
      const expected = `rides/${userId}/${ride.id}/original.gpx`;
      if (ride.gpx_path !== expected) {
        redirect(backToList(formData, { error: '轨迹文件路径异常，账号未删除' }));
      }
      paths.push(expected);
    }
    if ((rides?.length ?? 0) < 500) break;
  }

  // 2. Objects, in chunks — the Storage API takes a list per call.
  let removedFiles = 0;
  for (let i = 0; i < paths.length; i += 100) {
    const slice = paths.slice(i, i + 100);
    const { data: removed, error: removeError } = await admin.storage
      .from('rides')
      .remove(slice);
    if (removeError) {
      redirect(backToList(formData, { error: '删除轨迹文件失败，账号未删除，请稍后重试' }));
    }
    removedFiles += removed?.length ?? 0;
  }

  // 3. The account. Rows follow by cascade.
  const { error } = await admin.auth.admin.deleteUser(userId);
  if (error) {
    redirect(backToList(formData, { error: error.message }));
  }

  const { error: auditError } = await admin.from('admin_audit').insert({
    admin_id: user.id,
    action: 'delete_user',
    target_user_id: userId,
    detail: { files: removedFiles },
  });
  if (auditError) {
    redirect(backToList(formData, { error: '账号已删除，但审计日志写入失败，请检查后台' }));
  }

  revalidatePath('/users');
  revalidatePath('/audit');
  redirect('/users');
}
