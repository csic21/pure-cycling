import Link from 'next/link';
import { redirect } from 'next/navigation';

import { ConsoleShell } from '@/components/console-shell';
import { createClient } from '@/lib/supabase/server';

import { deleteUser } from '../../actions';

type AdminUser = {
  id: string;
  email: string | null;
  created_at: string;
  ride_count: number;
  route_count: number;
  is_admin: boolean;
};

/**
 * The confirmation step for deleting an account.
 *
 * A whole page rather than a button with a browser `confirm()`: this action
 * cannot be undone, and the operator should be able to read what exactly is
 * about to disappear — including the GPX files, which are the part nobody
 * remembers is there.
 */
export default async function DeleteUserPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data, error } = await supabase.rpc('admin_list_users', {
    p_limit: 200,
    p_offset: 0,
  });
  const who = user.email ?? user.id.slice(0, 8);

  if (error) {
    return (
      <ConsoleShell active="users" email={who}>
        <main className="page">
          <div className="notice">
            <strong>没有权限</strong>
            <p>{error.message}</p>
          </div>
          <Link href="/users">返回账号列表</Link>
        </main>
      </ConsoleShell>
    );
  }

  const target = ((data ?? []) as AdminUser[]).find((row) => row.id === id);

  if (!target) {
    return (
      <ConsoleShell active="users" email={who}>
        <main className="page">
          <div className="notice">
            <strong>找不到这个账号</strong>
            <p>列表最多显示 200 个账号；如果账号更多，先在列表里翻到它再试。</p>
          </div>
          <Link href="/users">返回账号列表</Link>
        </main>
      </ConsoleShell>
    );
  }

  if (target.is_admin) {
    return (
      <ConsoleShell active="users" email={who}>
        <main className="page">
          <div className="notice">
            <strong>这是管理员账号</strong>
            <p>先从通知名单里移除，再来删除。避免后台把自己锁在外面。</p>
          </div>
          <Link href="/users">返回账号列表</Link>
        </main>
      </ConsoleShell>
    );
  }

  return (
    <ConsoleShell active="users" email={who}>
      <main className="page">
        <div className="page-head">
          <h1>删除账号</h1>
        </div>

        <div className="notice">
          <strong>这一步不可恢复</strong>
          <p>
            将永久删除 {target.email ?? '这个匿名账号'}，连同云端的{' '}
            {target.ride_count} 条骑行、{target.route_count} 条路线、账号设置，
            以及 Storage 里的 GPX 文件。对方设备上的本地记录不受影响，
            但云端不会再有任何副本。
          </p>
        </div>

        <table className="table-users">
          <tbody>
            <tr>
              <th>账号</th>
              <td>{target.email ?? '匿名账号'}</td>
            </tr>
            <tr>
              <th>ID</th>
              <td className="mono">{target.id}</td>
            </tr>
            <tr>
              <th>骑行 / 路线</th>
              <td className="num">
                {target.ride_count} / {target.route_count}
              </td>
            </tr>
          </tbody>
        </table>

        <div className="row-actions" style={{ marginTop: 24 }}>
          <form action={deleteUser}>
            <input type="hidden" name="userId" value={target.id} />
            <button
              type="submit"
              className="row-action"
              style={{ borderColor: 'var(--danger)', color: 'var(--danger)' }}
            >
              永久删除这个账号
            </button>
          </form>
          <Link className="row-action" href="/users">
            取消
          </Link>
        </div>
      </main>
    </ConsoleShell>
  );
}
