import { redirect } from 'next/navigation';

import { createClient } from '@/lib/supabase/server';

import { signIn } from './actions';

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (user) redirect('/users');

  const { error } = await searchParams;

  return (
    <main className="centered">
      <form className="card" action={signIn}>
        <h1>管理后台</h1>
        <p className="muted small">
          用管理员账号登录。账号要先在 Supabase 里存在，并被加进
          <code> public.admins</code>。
        </p>
        {error ? <p className="error">{error}</p> : null}
        <label>
          邮箱
          <input
            name="email"
            type="email"
            required
            autoComplete="username"
            placeholder="admin@example.com"
          />
        </label>
        <label>
          密码
          <input
            name="password"
            type="password"
            required
            autoComplete="current-password"
          />
        </label>
        <button type="submit">登录</button>
      </form>
    </main>
  );
}
