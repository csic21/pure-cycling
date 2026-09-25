import Link from 'next/link';

import { signOut } from '@/app/login/actions';

/**
 * The masthead every console page shares.
 *
 * There are two sections and one operator; a sidebar would be furniture. The
 * active tab is marked with the accent rule — the same "this is live" colour
 * the app uses, and the only place it appears outside a primary action.
 */
export function ConsoleShell({
  active,
  email,
  children,
}: {
  active: 'users' | 'audit';
  email: string;
  children: React.ReactNode;
}) {
  return (
    <>
      <header className="masthead">
        <div className="wordmark">
          纯粹骑行<span>控制台</span>
        </div>
        <nav>
          <Link
            className="tab"
            aria-current={active === 'users' ? 'page' : undefined}
            href="/users"
          >
            账号
          </Link>
          <Link
            className="tab"
            aria-current={active === 'audit' ? 'page' : undefined}
            href="/audit"
          >
            审计
          </Link>
          <span className="who">{email}</span>
          <form action={signOut}>
            <button className="quiet" type="submit">
              退出
            </button>
          </form>
        </nav>
      </header>
      {children}
    </>
  );
}
