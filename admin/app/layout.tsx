import type { Metadata } from 'next';

import './globals.css';

export const metadata: Metadata = {
  title: '纯粹骑行 · 管理后台',
  // The console is an operations tool, not a landing page.
  robots: { index: false, follow: false },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="zh-CN">
      <body>{children}</body>
    </html>
  );
}
