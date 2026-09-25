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

export default async function AuditPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data, error } = await supabase
    .from('admin_audit')
    .select('id, admin_id, action, target_user_id, detail, created_at')
    .order('created_at', { ascending: false })
    .limit(200);

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

  return (
    <ConsoleShell active="audit" email={who}>
      <main className="page">
        <div className="page-head">
          <h1>审计</h1>
          <span className="quiet small num">最近 {rows.length} 条</span>
        </div>

        {rows.length === 0 ? (
          <p className="empty">还没有操作记录。封禁或解封账号后会出现在这里。</p>
        ) : (
          <div className="table-scroll">
            <table>
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

        <p className="footnote">
          记录只增不改。管理员或目标账号被删除之后，这里的行仍然保留。
        </p>
      </main>
    </ConsoleShell>
  );
}
