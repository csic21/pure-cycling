import type { NextConfig } from 'next';
import path from 'node:path';

const nextConfig: NextConfig = {
  // The server action shares cleanup logic with Edge Functions one directory
  // above admin/. Include it in module resolution and production tracing.
  turbopack: { root: path.resolve(process.cwd(), '..') },
  outputFileTracingRoot: path.resolve(process.cwd(), '..'),
  // The console talks to Supabase from server components and server actions.
  // Nothing here needs a public directory of assets yet.
  reactStrictMode: true,
};

export default nextConfig;
