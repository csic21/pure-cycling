import Link from 'next/link';
import { redirect } from 'next/navigation';

import { createClient } from '@/lib/supabase/server';
import { signOut } from '../login/actions';

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

function formatTime(value: string): string {
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

  if (error) {
    return (
      <main className="centered">
        <div className="card">
          <h1>没有权限</h1>
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

  const rows = (data ?? []) as AuditRow[];

  return (
    <main className="page">
      <header className="topbar">
        <div>
          <h1>审计日志</h1>
          <p className="muted small">最近 {rows.length} 条操作记录</p>
        </div>
        <nav>
          <Link href="/users">账号</Link>
          <form action={signOut}>
            <button type="submit" className="secondary">
              退出
            </button>
          </form>
        </nav>
      </header>

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
              <td className="muted small">{formatTime(row.created_at)}</td>
              <td>{ACTION_LABELS[row.action] ?? row.action}</td>
              <td className="muted small">{row.admin_id.slice(0, 8)}…</td>
              <td className="muted small">
                {row.target_user_id ? `${row.target_user_id.slice(0, 8)}…` : '—'}
              </td>
              <td className="muted small">
                {Object.keys(row.detail ?? {}).length === 0
                  ? '—'
                  : JSON.stringify(row.detail)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {rows.length === 0 ? (
        <p className="muted" style={{ marginTop: 16 }}>
          还没有操作记录。
        </p>
      ) : null}
    </main>
  );
}
