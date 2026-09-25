import Link from 'next/link';
import { redirect } from 'next/navigation';

import { ConsoleShell } from '@/components/console-shell';
import { signOut } from '@/app/login/actions';
import { createClient } from '@/lib/supabase/server';

type AuditRow = {
  id: number;
  admin_id: string;
  action: string;
  target_user_id: string | null;
  detail: Record<string, unknown>;
  created_at: string;
};

const ACTION_LABELS: Record<string, string> = {
  disable_user: '封禁账号',
  enable_user: '解封账号',
  verify_migrations: '验证脚本',
};

function stamp(value: string): string {
  return new Date(value).toLocaleString('zh-CN', {
    dateStyle: 'short',
    timeStyle: 'short',
  });
}

/// One page of the log.
///
/// The first version asked for 200 rows and stopped, with no way to tell
/// whether that was all of them. An audit log whose *end* is silently
/// truncated is worse than a short one: it reads as "this is everything that
/// happened". The count comes back with the page, so the header can say how
/// much there is.
const PAGE_SIZE = 100;

export default async function AuditPage({
  searchParams,
}: {
  searchParams: Promise<{ page?: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const parsed = await searchParams;
  const page = Math.max(1, Number.parseInt(parsed.page ?? '1', 10) || 1);
  const offset = (page - 1) * PAGE_SIZE;

  const { data, error, count } = await supabase
    .from('admin_audit')
    .select('id, admin_id, action, target_user_id, detail, created_at', {
      count: 'exact',
    })
    .order('created_at', { ascending: false })
    .range(offset, offset + PAGE_SIZE - 1);

  const who = user.email ?? user.id.slice(0, 8);

  if (error) {
    return (
      <main className="auth">
        <div className="auth-panel">
          <h1>没有权限</h1>
          <p className="muted small">{who} 不在管理员名单里。</p>
          <form action={signOut} style={{ marginTop: 20 }}>
            <button className="primary" type="submit">
              退出登录
            </button>
          </form>
        </div>
      </main>
    );
  }

  const rows = (data ?? []) as AuditRow[];
  const total = count ?? null;
  const hasNext = rows.length === PAGE_SIZE;
  const hasPrev = page > 1;

  return (
    <ConsoleShell active="audit" email={who}>
      <main className="page">
        <div className="page-head">
          <h1>审计</h1>
          <span className="quiet small num">
            {total === null ? `本页 ${rows.length} 条` : `共 ${total} 条`}
          </span>
        </div>

        {rows.length === 0 ? (
          <p className="empty">还没有操作记录。封禁或解封账号后会出现在这里。</p>
        ) : (
          <div className="table-scroll">
            <table className="table-audit">
              <thead>
                <tr>
                  <th>时间</th>
                  <th>操作</th>
                  <th>管理员</th>
                  <th>目标账号</th>
                  <th>详情</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.id}>
                    <td className="mono">{stamp(row.created_at)}</td>
                    <td>{ACTION_LABELS[row.action] ?? row.action}</td>
                    <td className="mono">{row.admin_id.slice(0, 13)}</td>
                    <td className="mono">
                      {row.target_user_id
                        ? row.target_user_id.slice(0, 13)
                        : '—'}
                    </td>
                    <td className="mono wrap">
                      {Object.keys(row.detail ?? {}).length === 0
                        ? '—'
                        : JSON.stringify(row.detail)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {hasPrev || hasNext ? (
          <nav className="pager">
            {hasPrev ? (
              <Link href={page === 2 ? '/audit' : `/audit?page=${page - 1}`}>
                ← 上一页
              </Link>
            ) : (
              <span />
            )}
            <span className="quiet small num">第 {page} 页</span>
            {hasNext ? (
              <Link href={`/audit?page=${page + 1}`}>下一页 →</Link>
            ) : (
              <span />
            )}
          </nav>
        ) : null}

        <p className="footnote">
          记录只增不改。管理员或目标账号被删除之后，这里的行仍然保留。
        </p>
      </main>
    </ConsoleShell>
  );
}
