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
    <main className="auth">
      <div className="auth-panel">
        <h1>管理后台</h1>
        <p className="muted small">只有名单里的账号能进来。</p>

        {error ? (
          <div className="notice" style={{ marginTop: 20 }}>
            <strong>登录失败</strong>
            <p>{error}</p>
          </div>
        ) : null}

        <form action={signIn}>
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
          <button className="primary" type="submit">
            登录
          </button>
        </form>
      </div>
    </main>
  );
}
