import { redirect } from 'next/navigation';

import { ConsoleShell } from '@/components/console-shell';
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

function stamp(value: string): string {
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
  const who = user.email ?? user.id.slice(0, 8);

  // A signed-in account that is not in `public.admins` gets a refusal from
  // the function itself, not an empty list — say so rather than showing a
  // zero-account table.
  if (error) {
    return (
      <main className="auth">
        <div className="auth-panel">
          <h1>没有权限</h1>
          <p className="muted small">
            {who} 不在管理员名单里，读不到任何数据。
          </p>
          <div className="notice" style={{ marginTop: 20 }}>
            <strong>数据库拒绝了这次读取</strong>
            <p>{error.message}</p>
          </div>
          <form action={signOut}>
            <button className="primary" type="submit">
              退出登录
            </button>
          </form>
        </div>
      </main>
    );
  }

  const users = (data ?? []) as AdminUser[];

  return (
    <ConsoleShell active="users" email={who}>
      <main className="page">
        <div className="page-head">
          <h1>账号</h1>
          <span className="quiet small num">共 {users.length} 个</span>
        </div>

        {pageError ? (
          <div className="notice">
            <strong>操作没有完成</strong>
            <p>{pageError}</p>
          </div>
        ) : null}

        {users.length === 0 ? (
          <p className="empty">
            还没有账号。先在 App 里注册一个，再把它加进管理员名单。
          </p>
        ) : (
          <div className="table-scroll">
            <table className="table-users">
              <thead>
                <tr>
                  <th>账号</th>
                  <th>注册</th>
                  <th>最后登录</th>
                  <th className="right">骑行</th>
                  <th className="right">路线</th>
                  <th>角色</th>
                  <th>状态</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {users.map((row) => {
                  const banned = row.access_state === 'disabled';
                  return (
                    <tr key={row.id}>
                      <td className="wrap">
                        <div className="cell-title">
                          <span>{row.email ?? '匿名账号'}</span>
                          {row.email && !row.email_confirmed ? (
                            <span className="tag">未验证</span>
                          ) : null}
                        </div>
                        <div className="cell-sub mono">{row.id.slice(0, 13)}</div>
                      </td>
                      <td className="muted small">{stamp(row.created_at)}</td>
                      <td className="muted small">
                        {row.last_sign_in_at ? stamp(row.last_sign_in_at) : '从未'}
                      </td>
                      <td className="right num">{row.ride_count}</td>
                      <td className="right num">{row.route_count}</td>
                      <td className="small muted">
                        {row.is_admin ? '管理员' : '骑手'}
                      </td>
                      <td>
                        <span className={banned ? 'status banned' : 'status'}>
                          {banned ? '已封禁' : '正常'}
                        </span>
                      </td>
                      <td className="right">
                        {row.is_admin ? null : (
                          <form action={setUserDisabled}>
                            <input type="hidden" name="userId" value={row.id} />
                            <input
                              type="hidden"
                              name="disabled"
                              value={banned ? 'false' : 'true'}
                            />
                            <button
                              type="submit"
                              className={
                                banned ? 'row-action restore' : 'row-action'
                              }
                            >
                              {banned ? '解封' : '封禁'}
                            </button>
                          </form>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        <p className="footnote">
          这里只有账号元数据，读不到骑行内容、GPX 或位置轨迹。
          这是产品承诺，不是权限配置疏漏。
        </p>
      </main>
    </ConsoleShell>
  );
}
