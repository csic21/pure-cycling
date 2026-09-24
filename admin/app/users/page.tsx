import Link from 'next/link';
import { redirect } from 'next/navigation';

import { createClient } from '@/lib/supabase/server';
import { signOut } from '../login/actions';
import { setUserDisabled } from './actions';

/// The shape of `admin_list_users()`. Kept next to the page rather than
/// generated, because it is one function; when a second one appears, replace
/// both with `supabase gen types typescript`.
type AdminUser = {
  id: string;
  email: string | null;
  email_confirmed: boolean;
  created_at: string;
  last_sign_in_at: string | null;
  ride_count: number;
  route_count: number;
  is_admin: boolean;
  access_state: string;
};

function formatTime(value: string): string {
  return new Date(value).toLocaleString('zh-CN', {
    dateStyle: 'short',
    timeStyle: 'short',
  });
}

export default async function UsersPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data, error } = await supabase.rpc('admin_list_users', {
    p_limit: 100,
    p_offset: 0,
  });
  const { error: pageError } = await searchParams;

  // A signed-in account that is not in `public.admins` gets a refusal from
  // the function itself, not an empty list — say so rather than showing a
  // zero-account table.
  if (error) {
    return (
      <main className="centered">
        <div className="card">
          <h1>没有权限</h1>
          <p className="muted">
            当前账号（{user.email ?? user.id.slice(0, 8)}）不在管理员名单里。
          </p>
          <p className="muted small">{error.message}</p>
          <form action={signOut}>
            <button type="submit" className="secondary">
              退出登录
            </button>
          </form>
        </div>
      </main>
    );
  }

  const users = (data ?? []) as AdminUser[];

  return (
    <main className="page">
      <header className="topbar">
        <div>
          <h1>账号</h1>
          <p className="muted small">
            共 {users.length} 个账号 · 当前 {user.email ?? user.id.slice(0, 8)}
          </p>
        </div>
        <nav>
          <Link href="/audit">审计日志</Link>
          <form action={signOut}>
            <button type="submit" className="secondary">
              退出
            </button>
          </form>
        </nav>
      </header>

      {pageError ? <p className="error">{pageError}</p> : null}

      <table>
        <thead>
          <tr>
            <th>账号</th>
            <th>注册</th>
            <th>最后登录</th>
            <th>骑行</th>
            <th>路线</th>
            <th>角色</th>
            <th>状态</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {users.map((row) => {
            const disabled = row.access_state === 'disabled';
            return (
              <tr key={row.id}>
                <td>
                  <div>{row.email ?? '匿名账号'}</div>
                  <div className="muted small">
                    {row.id.slice(0, 8)}…
                    {row.email && !row.email_confirmed ? ' · 邮箱未验证' : ''}
                  </div>
                </td>
                <td className="muted small">{formatTime(row.created_at)}</td>
                <td className="muted small">
                  {row.last_sign_in_at ? formatTime(row.last_sign_in_at) : '—'}
                </td>
                <td>{row.ride_count}</td>
                <td>{row.route_count}</td>
                <td>{row.is_admin ? '管理员' : '骑手'}</td>
                <td>
                  <span className={disabled ? 'badge danger' : 'badge'}>
                    {disabled ? '已封禁' : '正常'}
                  </span>
                </td>
                <td>
                  {row.is_admin ? null : (
                    <form action={setUserDisabled}>
                      <input type="hidden" name="userId" value={row.id} />
                      <input
                        type="hidden"
                        name="disabled"
                        value={disabled ? 'false' : 'true'}
                      />
                      <button
                        type="submit"
                        className={disabled ? 'secondary' : 'danger'}
                      >
                        {disabled ? '解封' : '封禁'}
                      </button>
                    </form>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      <p className="muted small" style={{ marginTop: 16 }}>
        这里只有账号元数据。骑行内容、GPX 和位置轨迹不在列表里，也读不到 ——
        这是产品承诺，不是权限配置的疏漏。
      </p>
    </main>
  );
}
