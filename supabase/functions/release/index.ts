import { handleRelease } from "./handler.ts";
import { postgresReleaseCache } from "./cache_store.ts";

Deno.serve((req) => {
  const repository = Deno.env.get("RELEASE_REPOSITORY") ??
    "csic21/pure-cycling";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceKey) {
    return new Response(JSON.stringify({ code: "release_unavailable" }), {
      status: 503,
      headers: {
        "Content-Type": "application/json",
        "X-Release-Repository": repository,
        "Cache-Control": "no-store",
      },
    });
  }
  return handleRelease(req, {
    fetch: fetch,
    cache: postgresReleaseCache(fetch, supabaseUrl, serviceKey),
    env: {
      repository,
      githubBase: "https://api.github.com",
      token: Deno.env.get("GITHUB_TOKEN") ?? "",
      upstreamTimeoutMs: 2500,
    },
  });
});
