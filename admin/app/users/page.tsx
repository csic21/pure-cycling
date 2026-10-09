import Link from 'next/link';
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
  total: number;
};

/// One page of accounts. The console is an operations tool for a small team:
/// fifty rows is enough to scan, small enough that a query stays cheap.
const PAGE_SIZE = 50;

function stamp(value: string): string {
  return new Date(value).toLocaleString('zh-CN', {
    dateStyle: 'short',
    timeStyle: 'short',
  });
}

/// Builds a `/users` link that keeps the current filter.
function usersHref(search: string, page: number): string {
  const params = new URLSearchParams();
  if (search) params.set('q', search);
  if (page > 1) params.set('page', String(page));
  const query = params.toString();
  return query ? `/users?${query}` : '/users';
}

export default async function UsersPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string; q?: string; page?: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const parsed = await searchParams;
  const { error: pageError } = parsed;
  const search = (parsed.q ?? '').trim();
  const page = Math.max(1, Number.parseInt(parsed.page ?? '1', 10) || 1);

  const { data, error } = await supabase.rpc('admin_list_users', {
    p_search: search === '' ? null : search,
    p_limit: PAGE_SIZE,
    p_offset: (page - 1) * PAGE_SIZE,
  });
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
  // Present on every row when there is at least one, and therefore unknown on
  // an empty page past the end. Showing 「共 0 个」 for "past the end of a
  // filtered list" would be a lie.
  const total = users.length > 0 ? Number(users[0].total) : null;
  const hasNext = users.length === PAGE_SIZE;
  const hasPrev = page > 1;

  return (
    <ConsoleShell active="users" email={who}>
      <main className="page">
        <div className="page-head">
          <h1>账号</h1>
          <span className="quiet small num">
            {total === null
              ? '没有匹配'
              : search
                ? `匹配 ${total} 个`
                : `共 ${total} 个`}
          </span>
        </div>

        <form className="filter" action="/users" method="get">
          <input
            type="search"
            name="q"
            defaultValue={search}
            placeholder="按邮箱搜索"
            aria-label="按邮箱搜索"
            autoComplete="off"
          />
          <button type="submit">搜索</button>
          {search ? (
            <Link className="quiet-link" href="/users">
              清除筛选
            </Link>
          ) : null}
        </form>

        {pageError ? (
          <div className="notice">
            <strong>操作没有完成</strong>
            <p>{pageError}</p>
          </div>
        ) : null}

        {users.length === 0 ? (
          <p className="empty">
            {search
              ? `没有邮箱包含「${search}」的账号。匿名账号没有邮箱，只在不筛选时出现在列表里。`
              : '还没有账号。先在 App 里注册一个，再把它加进管理员名单。'}
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
                  const cleaning = row.access_state === 'wipe' || row.access_state === 'delete';
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
                        <span className={banned || cleaning ? 'status banned' : 'status'}>
                          {cleaning ? '清理待完成' : banned ? '已封禁' : '正常'}
                        </span>
                      </td>
                      <td className="right">
                        {row.is_admin ? null : (
                          <div className="row-actions">
                            {cleaning ? null : <form action={setUserDisabled}>
                              <input type="hidden" name="userId" value={row.id} />
                              <input
                                type="hidden"
                                name="disabled"
                                value={banned ? 'false' : 'true'}
                              />
                              {/* Keeps the operator's filter and page after the
                                  action redirects back to the list. */}
                              <input type="hidden" name="q" value={search} />
                              <input type="hidden" name="page" value={String(page)} />
                              <button
                                type="submit"
                                className={
                                  banned ? 'row-action restore' : 'row-action'
                                }
                              >
                                {banned ? '解封' : '封禁'}
                              </button>
                            </form>}
                            <Link
                              className="row-action"
                              href={`/users/${row.id}/delete`}
                            >
                              {cleaning ? '重试删除' : '删除'}
                            </Link>
                          </div>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        {hasPrev || hasNext ? (
          <nav className="pager">
            {hasPrev ? (
              <Link href={usersHref(search, page - 1)}>← 上一页</Link>
            ) : (
              <span />
            )}
            <span className="quiet small num">第 {page} 页</span>
            {hasNext ? (
              <Link href={usersHref(search, page + 1)}>下一页 →</Link>
            ) : (
              <span />
            )}
          </nav>
        ) : null}

        <p className="footnote">
          这里只有账号元数据，读不到骑行内容、GPX 或位置轨迹。
          这是产品承诺，不是权限配置疏漏。
        </p>
      </main>
    </ConsoleShell>
  );
}
