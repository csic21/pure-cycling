'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';

import { createAdminClient } from '@/lib/supabase/admin';
import { createClient } from '@/lib/supabase/server';
import { cleanupAccount, isUserId } from '../../../supabase/functions/_shared/account-cleanup';

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
  if (!isUserId(targetUserId)) {
    redirect(backToList(formData, { error: '账号 ID 无效' }));
  }
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
  return { user, admin, supabase };
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

  const { admin, supabase } = await requireActingAdmin(userId, formData);

  // Disable Data/Storage first. An existing JWT remains cryptographically
  // valid after GoTrue's ban; the database is the immediate access boundary.
  // Enabling does the reverse, so a failed step never opens data access.
  if (disabled) {
    const { error } = await supabase.rpc('admin_set_account_disabled', {
      p_user_id: userId, p_disabled: true,
    });
    if (error) redirect(backToList(formData, { error: error.message }));
  }
  const { error } = await admin.auth.admin.updateUserById(userId, {
    ban_duration: disabled ? '876000h' : 'none',
  });
  if (error) {
    redirect(backToList(formData, {
      error: disabled ? '数据访问已封禁，但登录封禁未完成，请重试' : error.message,
    }));
  }
  if (!disabled) {
    const { error } = await supabase.rpc('admin_set_account_disabled', {
      p_user_id: userId, p_disabled: false,
    });
    if (error) redirect(backToList(formData, { error: '登录封禁已解除，数据访问仍被封禁，请重试' }));
  }

  revalidatePath('/users');
  revalidatePath('/audit');
  redirect(backToList(formData));
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

  let removedFiles: number;
  try {
    removedFiles = await cleanupAccount(userId, user.id, 'delete', {
      fetch,
      env: {
        supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL ?? '',
        anonKey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '',
        serviceKey: process.env.SUPABASE_SERVICE_ROLE_KEY ?? '',
      },
    });
  } catch (error) {
    redirect(backToList(formData, {
      error: error instanceof Error ? error.message : '账号清理尚未完成，请重试',
    }));
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
  redirect(backToList(formData));
}
