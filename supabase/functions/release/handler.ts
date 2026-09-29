// Public Release metadata, backed by a shared Postgres cache. Every Edge
// Function isolate has its own memory; the database lease is what prevents a
// cold-start burst from becoming a burst of GitHub API requests.

export interface ReleaseEnv {
  repository: string;
  githubBase: string;
  token: string;
  upstreamTimeoutMs: number;
}

export type FetchLike = typeof globalThis.fetch;

export type CacheDecision =
  | { state: "fresh" | "stale"; body: string; fetched_at: string }
  | { state: "refresh"; body: string | null; fetched_at: string | null }
  | { state: "missing" | "wait" | "unavailable" };

export interface ReleaseCache {
  claim(repository: string, leaseId: string): Promise<CacheDecision>;
  finish(
    repository: string,
    leaseId: string,
    status: 200 | 404,
    body: string | null,
  ): Promise<boolean>;
  fail(repository: string, leaseId: string): Promise<boolean>;
}

export interface ReleaseDeps {
  fetch: FetchLike;
  cache: ReleaseCache;
  env: ReleaseEnv;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  newLeaseId?: () => string;
}

const REPOSITORY = /^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_.-]+$/;
const wait = (ms: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));

export async function handleRelease(
  req: Request,
  {
    fetch: fetchImpl,
    cache,
    env,
    sleep = wait,
    now = Date.now,
    newLeaseId = () => crypto.randomUUID(),
  }: ReleaseDeps,
): Promise<Response> {
  const reply = (status: number, message: string) =>
    failure(status, message, env.repository);
  if (req.method !== "GET") return reply(405, "只接受 GET");
  if (
    !REPOSITORY.test(env.repository) ||
    env.repository.endsWith("/.") || env.repository.endsWith("/..")
  ) {
    return reply(503, "更新服务尚未正确配置");
  }

  const leaseId = newLeaseId();
  const waitUntil = now() + 6000;
  let decision: CacheDecision;
  try {
    decision = await cache.claim(env.repository, leaseId);
    while (decision.state === "wait" && now() < waitUntil) {
      await sleep(150);
      decision = await cache.claim(env.repository, leaseId);
    }
  } catch {
    return reply(503, "更新缓存暂时不可用");
  }

  if (decision.state === "fresh" || decision.state === "stale") {
    return answer(
      decision.body,
      env.repository,
      decision.state,
      decision.fetched_at,
      now(),
    );
  }
  if (decision.state === "missing") {
    return reply(404, "仓库还没有公开的 Release");
  }
  if (decision.state !== "refresh") return reply(503, "更新服务暂时不可用");

  const stale = decision.body === null ? null : answer(
    decision.body,
    env.repository,
    "stale",
    decision.fetched_at,
    now(),
  );
  const upstreamFailure = async (message: string): Promise<Response> => {
    try {
      await cache.fail(env.repository, leaseId);
    } catch {
      // A failed cache write must never trigger an uncontrolled second fetch.
    }
    return stale ?? reply(503, message);
  };

  const result = await lookupRelease(fetchImpl, env);
  if (result?.status === 404) {
    if (stale !== null) {
      return await upstreamFailure("GitHub 暂时无法提供 Release");
    }
    try {
      if (!await cache.finish(env.repository, leaseId, 404, null)) {
        return reply(503, "更新缓存暂时不可用");
      }
    } catch {
      return reply(503, "更新缓存暂时不可用");
    }
    return reply(404, "仓库还没有公开的 Release");
  }
  if (result === null) return await upstreamFailure("无法获取 GitHub Release");
  const body = result.body;

  try {
    if (!await cache.finish(env.repository, leaseId, 200, body)) {
      return reply(503, "更新缓存暂时不可用");
    }
  } catch {
    return reply(503, "更新缓存暂时不可用");
  }
  return answer(
    body,
    env.repository,
    "fresh",
    new Date(now()).toISOString(),
    now(),
  );
}

async function lookupRelease(
  fetchImpl: FetchLike,
  env: ReleaseEnv,
): Promise<{ status: 200; body: string } | { status: 404 } | null> {
  // The shared lease keeps this to one API call per repository per ten minutes.
  // A token is optional: GitHub's documented latest-release permalink is the
  // fallback when a shared cloud egress IP has exhausted its anonymous quota.
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "pure-cycling-release-relay",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (env.token) headers.Authorization = `Bearer ${env.token}`;
  try {
    const api = await fetchImpl(
      `${env.githubBase}/repos/${env.repository}/releases/latest`,
      { headers, signal: AbortSignal.timeout(env.upstreamTimeoutMs) },
    );
    if (api.ok) {
      const body = await api.text();
      if (isRelease(body, env.repository)) return { status: 200, body };
    }
  } catch {
    // Use the public website fallback below.
  }

  const latest = `https://github.com/${env.repository}/releases/latest`;
  let tag: string | null = null;
  try {
    const page = await fetchImpl(latest, {
      redirect: "manual",
      headers: { "User-Agent": "pure-cycling-release-relay" },
      signal: AbortSignal.timeout(env.upstreamTimeoutMs),
    });
    if (page.status === 404) return { status: 404 };
    if (![301, 302, 303, 307, 308].includes(page.status)) return null;
    const location = page.headers.get("Location");
    if (!location) return null;
    const url = new URL(location, latest);
    const prefix = `/${env.repository.toLowerCase()}/releases/tag/`;
    if (
      url.protocol !== "https:" || url.hostname !== "github.com" ||
      !url.pathname.toLowerCase().startsWith(prefix)
    ) return null;
    tag = decodeURIComponent(url.pathname.slice(prefix.length));
    if (!/^[vV]?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(tag)) return null;
  } catch {
    return null;
  }

  // Current CI publishes the first name; earlier releases used the second.
  // Only advertise an asset link after GitHub confirms it exists.
  //
  // The URL is pinned to the tag resolved above, never GitHub's
  // `/releases/latest/download/...` permalink. That permalink is resolved a
  // second time, by GitHub, when the rider's phone downloads the file — so a
  // cached body could promise one release's version number and hand over
  // another release's APK. The app rejects it outright as well: `_githubUri`
  // only accepts `/<repo>/releases/download/` paths, so advertising a
  // permalink left the Android updater with no install button at all.
  const assetNames = ["pure-cycling-android.apk", "app-release.apk"];
  const assetsBase = `https://github.com/${env.repository}/releases/download/${
    encodeURIComponent(tag)
  }`;
  const checks = await Promise.all(assetNames.map(async (name) => {
    const url = `${assetsBase}/${name}`;
    try {
      const response = await fetchImpl(url, {
        method: "HEAD",
        redirect: "manual",
        signal: AbortSignal.timeout(1500),
      });
      return response.ok || [301, 302, 303, 307, 308].includes(response.status)
        ? { name, url }
        : null;
    } catch {
      return null;
    }
  }));
  const asset = checks.find((value) => value !== null);
  const body = JSON.stringify({
    tag_name: tag,
    html_url: `https://github.com/${env.repository}/releases/tag/${
      encodeURIComponent(tag)
    }`,
    body: "请在 GitHub Release 页面查看更新内容。",
    assets: asset
      ? [{
        name: asset.name,
        browser_download_url: asset.url,
      }]
      : [],
  });
  return { status: 200, body };
}

function answer(
  body: string,
  repository: string,
  state: "fresh" | "stale",
  fetchedAt: string | null,
  at: number,
): Response {
  const age = fetchedAt === null
    ? 0
    : Math.max(0, Math.floor((at - Date.parse(fetchedAt)) / 1000));
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Release-Repository": repository,
      "X-Release-Cache": state,
      "X-Release-Age": String(Number.isFinite(age) ? age : 0),
    },
  });
}

function failure(
  status: number,
  message: string,
  repository: string,
): Response {
  return new Response(
    JSON.stringify({
      code: status === 404 ? "release_missing" : "release_unavailable",
      message,
    }),
    {
      status,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Release-Repository": repository,
      },
    },
  );
}

function isRelease(body: string, repository: string): boolean {
  if (new TextEncoder().encode(body).length > 1048576) return false;
  try {
    const value = JSON.parse(body) as Record<string, unknown>;
    if (
      value === null || typeof value !== "object" || Array.isArray(value) ||
      typeof value.tag_name !== "string" || typeof value.html_url !== "string"
    ) return false;
    const url = new URL(value.html_url);
    return url.protocol === "https:" && url.hostname === "github.com" &&
      url.pathname.toLowerCase().startsWith(
        `/${repository.toLowerCase()}/releases/tag/`,
      );
  } catch {
    return false;
  }
}
