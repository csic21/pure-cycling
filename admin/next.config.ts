import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // The console talks to Supabase from server components and server actions.
  // Nothing here needs a public directory of assets yet.
  reactStrictMode: true,
};

export default nextConfig;
