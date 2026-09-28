import type { CacheDecision, FetchLike, ReleaseCache } from "./handler.ts";

// PostgREST is used only from the Edge Function, with the platform-injected
// service key. The cache table and RPCs grant nothing to app roles.
export function postgresReleaseCache(
  fetchImpl: FetchLike,
  supabaseUrl: string,
  serviceKey: string,
): ReleaseCache {
  if (!supabaseUrl || !serviceKey) {
    throw new Error("release cache backend is not configured");
  }
  const base = new URL(`${supabaseUrl.replace(/\/+$/, "")}/rest/v1/rpc/`);

  async function rpc(
    name: string,
    args: Record<string, unknown>,
  ): Promise<unknown> {
    const response = await fetchImpl(new URL(name, base), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
      },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(2000),
    });
    if (!response.ok) {
      throw new Error(`release cache RPC ${name}: ${response.status}`);
    }
    return await response.json();
  }

  return {
    async claim(repository, leaseId): Promise<CacheDecision> {
      const result = await rpc("claim_release_cache", {
        p_repository: repository,
        p_lease_id: leaseId,
      });
      if (
        result === null || typeof result !== "object" || Array.isArray(result)
      ) {
        throw new Error("invalid release cache decision");
      }
      const value = result as Record<string, unknown>;
      switch (value.state) {
        case "fresh":
        case "stale":
          if (
            typeof value.body !== "string" ||
            typeof value.fetched_at !== "string"
          ) break;
          return {
            state: value.state,
            body: value.body,
            fetched_at: value.fetched_at,
          };
        case "refresh":
          if (
            (value.body !== null && typeof value.body !== "string") ||
            (value.fetched_at !== null && typeof value.fetched_at !== "string")
          ) break;
          return {
            state: "refresh",
            body: value.body,
            fetched_at: value.fetched_at,
          };
        case "missing":
        case "wait":
        case "unavailable":
          return { state: value.state };
      }
      throw new Error("invalid release cache decision");
    },
    async finish(repository, leaseId, status, body): Promise<boolean> {
      const result = await rpc("finish_release_cache", {
        p_repository: repository,
        p_lease_id: leaseId,
        p_status: status,
        p_body: body,
      });
      if (typeof result !== "boolean") {
        throw new Error("invalid release cache result");
      }
      return result;
    },
    async fail(repository, leaseId): Promise<boolean> {
      const result = await rpc("fail_release_cache", {
        p_repository: repository,
        p_lease_id: leaseId,
      });
      if (typeof result !== "boolean") {
        throw new Error("invalid release cache result");
      }
      return result;
    },
  };
}
