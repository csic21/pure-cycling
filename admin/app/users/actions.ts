'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';

import { createAdminClient } from '@/lib/supabase/admin';
import { createClient } from '@/lib/supabase/server';

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

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: isAdmin } = await supabase.rpc('is_admin');
  if (isAdmin !== true) {
    redirect(`/users?error=${encodeURIComponent('当前账号不是管理员')}`);
  }
  if (userId === user.id) {
    redirect(`/users?error=${encodeURIComponent('不能封禁自己的账号')}`);
  }

  const admin = createAdminClient();
  const { error } = await admin.auth.admin.updateUserById(userId, {
    // GoTrue takes a duration string; `none` lifts an existing ban.
    ban_duration: disabled ? '876000h' : 'none',
  });
  if (error) {
    redirect(`/users?error=${encodeURIComponent(error.message)}`);
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
