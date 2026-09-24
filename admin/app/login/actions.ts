'use server';

import { redirect } from 'next/navigation';

import { createClient } from '@/lib/supabase/server';

export async function signIn(formData: FormData) {
  const email = String(formData.get('email') ?? '').trim();
  const password = String(formData.get('password') ?? '');

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    redirect(`/login?error=${encodeURIComponent(describe(error.message))}`);
  }
  redirect('/users');
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect('/login');
}

/// The auth server speaks English; the operator should not have to.
function describe(message: string): string {
  const text = message.toLowerCase();
  if (text.includes('invalid login credentials')) return '邮箱或密码不正确';
  if (text.includes('email not confirmed')) return '邮箱尚未验证';
  if (text.includes('rate limit')) return '尝试过于频繁，请稍后再试';
  return message;
}
