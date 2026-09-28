import { postgresReleaseCache } from "./cache_store.ts";
import type { FetchLike } from "./handler.ts";

Deno.test("cache RPCs use the service key only on the Supabase REST endpoint", async () => {
  const calls: string[] = [];
  const fakeFetch: FetchLike = async (input, init) => {
    const url = String(input);
    if (!url.startsWith("https://project.supabase.co/rest/v1/rpc/")) {
      throw new Error(`unexpected URL: ${url}`);
    }
    const headers = new Headers(init?.headers);
    if (
      headers.get("apikey") !== "service-secret" ||
      headers.get("Authorization") !== "Bearer service-secret"
    ) {
      throw new Error("service key was not sent to PostgREST");
    }
    calls.push(url);
    if (url.endsWith("/claim_release_cache")) {
      return new Response(JSON.stringify({ state: "wait" }));
    }
    return new Response("true");
  };
  const cache = postgresReleaseCache(
    fakeFetch,
    "https://project.supabase.co/",
    "service-secret",
  );
  const decision = await cache.claim(
    "owner/repo",
    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  );
  if (decision.state !== "wait") throw new Error("invalid decision");
  if (!await cache.finish("owner/repo", "lease", 200, "{}")) {
    throw new Error("finish failed");
  }
  if (!await cache.fail("owner/repo", "lease")) throw new Error("fail failed");
  if (calls.length !== 3) {
    throw new Error(`expected three RPCs, got ${calls.length}`);
  }
});
