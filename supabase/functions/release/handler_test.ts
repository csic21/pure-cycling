import {
  type CacheDecision,
  type FetchLike,
  handleRelease,
  type ReleaseCache,
  type ReleaseDeps,
  type ReleaseEnv,
} from "./handler.ts";

function assert(condition: unknown, message: string): void {
  if (!condition) throw new Error(message);
}

function equal(actual: unknown, expected: unknown, message: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message}: got ${JSON.stringify(actual)}, expected ${
        JSON.stringify(expected)
      }`,
    );
  }
}

const repo = "csic21/pure-cycling";
const release = JSON.stringify({
  tag_name: "v0.2.0",
  html_url: `https://github.com/${repo}/releases/tag/v0.2.0`,
  body: "修复路线规划",
  assets: [],
});
const request = () => new Request("https://relay.test/release");

class SharedCache implements ReleaseCache {
  constructor(private readonly now: () => number) {}
  body: string | null = null;
  status: 200 | 404 | null = null;
  fetchedAt = 0;
  expiresAt = 0;
  leaseId: string | null = null;
  leaseUntil = 0;
  retryAfter = 0;

  async claim(_repository: string, leaseId: string): Promise<CacheDecision> {
    const at = this.now();
    if (this.expiresAt > at) {
      if (this.status === 404) return { state: "missing" };
      return {
        state: "fresh",
        body: this.body!,
        fetched_at: new Date(this.fetchedAt).toISOString(),
      };
    }
    if (this.leaseUntil > at) {
      if (this.body !== null) {
        return {
          state: "stale",
          body: this.body,
          fetched_at: new Date(this.fetchedAt).toISOString(),
        };
      }
      return { state: "wait" };
    }
    if (this.retryAfter > at) {
      if (this.body !== null) {
        return {
          state: "stale",
          body: this.body,
          fetched_at: new Date(this.fetchedAt).toISOString(),
        };
      }
      return { state: "unavailable" };
    }
    this.leaseId = leaseId;
    this.leaseUntil = at + 15000;
    return {
      state: "refresh",
      body: this.body,
      fetched_at: this.body === null
        ? null
        : new Date(this.fetchedAt).toISOString(),
    };
  }

  async finish(
    _repository: string,
    leaseId: string,
    status: 200 | 404,
    body: string | null,
  ): Promise<boolean> {
    if (this.leaseId !== leaseId || this.leaseUntil <= this.now()) return false;
    this.status = status;
    this.body = body;
    this.fetchedAt = this.now();
    this.expiresAt = this.now() + (status === 200 ? 600000 : 30000);
    this.leaseId = null;
    this.leaseUntil = 0;
    this.retryAfter = 0;
    return true;
  }

  async fail(_repository: string, leaseId: string): Promise<boolean> {
    if (this.leaseId !== leaseId) return false;
    this.leaseId = null;
    this.leaseUntil = 0;
    this.retryAfter = this.now() + 30000;
    return true;
  }
}

function deps(
  cache: ReleaseCache,
  github: FetchLike,
  overrides: Partial<ReleaseEnv> = {},
  now = Date.now,
): ReleaseDeps {
  return {
    cache,
    fetch: github,
    now,
    env: {
      repository: repo,
      githubBase: "https://api.github.com",
      token: "test-token",
      upstreamTimeoutMs: 4000,
      ...overrides,
    },
  };
}

Deno.test("returns GitHub JSON and keeps the repository visible for release CI", async () => {
  const cache = new SharedCache(Date.now);
  let calls = 0;
  const github: FetchLike = (_url, init) => {
    calls++;
    equal(
      String(_url),
      `https://api.github.com/repos/${repo}/releases/latest`,
      "upstream URL",
    );
    equal(
      new Headers(init?.headers).get("Authorization"),
      "Bearer test-token",
      "token",
    );
    return Promise.resolve(new Response(release));
  };
  const first = await handleRelease(request(), deps(cache, github));
  equal(first.status, 200, "first status");
  equal(first.headers.get("X-Release-Repository"), repo, "repository header");
  equal(first.headers.get("Cache-Control"), "no-store", "HTTP cache policy");
  equal(await first.text(), release, "response body");
  const second = await handleRelease(request(), deps(cache, github));
  equal(second.status, 200, "cached status");
  equal(calls, 1, "only one upstream call");
});

Deno.test("twenty-five simultaneous cold requests share one upstream call", async () => {
  const cache = new SharedCache(Date.now);
  let calls = 0;
  const github: FetchLike = async () => {
    calls++;
    await new Promise((resolve) => setTimeout(resolve, 40));
    return new Response(release);
  };
  const responses = await Promise.all(
    Array.from(
      { length: 25 },
      () => handleRelease(request(), deps(cache, github)),
    ),
  );
  equal(
    responses.map((response) => response.status),
    Array(25).fill(200),
    "all riders get a release",
  );
  equal(calls, 1, "only one GitHub call");
});

Deno.test("expired cache is refreshed and stale data is served during refresh", async () => {
  let clock = Date.now();
  const now = () => clock;
  const cache = new SharedCache(now);
  let calls = 0;
  const github: FetchLike = async () => {
    calls++;
    return new Response(release);
  };
  await handleRelease(request(), deps(cache, github, {}, now));
  clock += 601000;
  const refresh = handleRelease(request(), deps(cache, github, {}, now));
  const stale = await handleRelease(request(), deps(cache, github, {}, now));
  equal(stale.status, 200, "stale status");
  equal(stale.headers.get("X-Release-Cache"), "stale", "stale marker");
  equal((await refresh).status, 200, "refresh status");
  equal(calls, 2, "one refresh");
});

Deno.test("outage serves stale data and backs off further GitHub requests", async () => {
  let clock = Date.now();
  const now = () => clock;
  const cache = new SharedCache(now);
  let calls = 0;
  const github: FetchLike = async () => {
    calls++;
    if (calls > 1) throw new Error("network down");
    return new Response(release);
  };
  await handleRelease(request(), deps(cache, github, {}, now));
  clock += 601000;
  const failedRefresh = await handleRelease(
    request(),
    deps(cache, github, {}, now),
  );
  equal(failedRefresh.status, 200, "stale response on outage");
  equal(failedRefresh.headers.get("X-Release-Cache"), "stale", "stale marker");
  await handleRelease(request(), deps(cache, github, {}, now));
  equal(calls, 3, "backoff prevents more calls after API and website fail");
});

Deno.test("missing release is cached briefly with a distinct error code", async () => {
  let clock = Date.now();
  const now = () => clock;
  const cache = new SharedCache(now);
  let calls = 0;
  const github: FetchLike = async () => {
    calls++;
    return new Response("{}", { status: 404 });
  };
  const first = await handleRelease(request(), deps(cache, github, {}, now));
  equal(first.status, 404, "missing status");
  equal((await first.json()).code, "release_missing", "error code");
  await handleRelease(request(), deps(cache, github, {}, now));
  equal(calls, 2, "negative cache after API and website return 404");
  clock += 31000;
  await handleRelease(request(), deps(cache, github, {}, now));
  equal(calls, 4, "negative cache expires quickly");
});

Deno.test("invalid or unconfigured source never reaches GitHub", async () => {
  const cache = new SharedCache(Date.now);
  let calls = 0;
  const github: FetchLike = async () => {
    calls++;
    return new Response(release);
  };
  for (
    const overrides of [
      { repository: "../other" },
      { repository: "owner/.." },
      { repository: "" },
    ]
  ) {
    const response = await handleRelease(
      request(),
      deps(cache, github, overrides),
    );
    equal(response.status, 503, "configuration failure");
  }
  equal(calls, 0, "no GitHub calls");
});

Deno.test("anonymous API rate limit falls back to a tag-pinned release asset", async () => {
  const cache = new SharedCache(Date.now);
  const seen: string[] = [];
  const github: FetchLike = async (input, init) => {
    const url = String(input);
    seen.push(url);
    if (url.startsWith("https://api.github.com/")) {
      equal(
        new Headers(init?.headers).has("Authorization"),
        false,
        "anonymous API call",
      );
      return new Response("rate limited", { status: 403 });
    }
    if (url.endsWith("/releases/latest")) {
      return new Response(null, {
        status: 302,
        headers: { Location: `https://github.com/${repo}/releases/tag/v0.2.0` },
      });
    }
    if (url.endsWith("/releases/download/v0.2.0/pure-cycling-android.apk")) {
      equal(init?.method, "HEAD", "asset existence check");
      return new Response(null, { status: 302 });
    }
    // Anything else, including GitHub's `/releases/latest/download/...`
    // permalink, fails the probe. That permalink is resolved again when the
    // phone downloads, so advertising it could pair one version number with
    // another release's file — and the app refuses the path outright.
    throw new Error(`unexpected URL: ${url}`);
  };
  const response = await handleRelease(
    request(),
    deps(cache, github, { token: "" }),
  );
  equal(response.status, 200, "fallback status");
  const body = await response.json();
  equal(body.tag_name, "v0.2.0", "fallback tag");
  equal(body.assets[0].name, "pure-cycling-android.apk", "verified APK");
  equal(
    body.assets[0].browser_download_url,
    `https://github.com/${repo}/releases/download/v0.2.0/pure-cycling-android.apk`,
    "APK link carries the same tag as tag_name",
  );
  equal(seen.length, 4, "one API, one release link, two known asset checks");
});

Deno.test("website fallback finds the APK name used by existing releases", async () => {
  const github: FetchLike = async (input) => {
    const url = String(input);
    if (url.startsWith("https://api.github.com/")) {
      return new Response("rate limited", { status: 403 });
    }
    if (url.endsWith("/releases/latest")) {
      return new Response(null, {
        status: 302,
        headers: { Location: `https://github.com/${repo}/releases/tag/v0.1.1` },
      });
    }
    return new Response(null, {
      status: url.endsWith("/app-release.apk") ? 302 : 404,
    });
  };
  const response = await handleRelease(
    request(),
    deps(new SharedCache(Date.now), github, { token: "" }),
  );
  const body = await response.json();
  equal(body.assets[0].name, "app-release.apk", "existing APK name");
});

Deno.test("website fallback refuses a redirect to another repository", async () => {
  const github: FetchLike = async (input) =>
    String(input).startsWith("https://api.github.com/")
      ? new Response("rate limited", { status: 403 })
      : new Response(null, {
        status: 302,
        headers: {
          Location: "https://github.com/other/project/releases/tag/v1.0.0",
        },
      });
  const response = await handleRelease(
    request(),
    deps(new SharedCache(Date.now), github, { token: "" }),
  );
  equal(response.status, 503, "cross-repository redirect is rejected");
});

Deno.test("rejects a release body pointing to a different repository", async () => {
  const cache = new SharedCache(Date.now);
  const bad = release.replaceAll(repo, "other/project");
  const response = await handleRelease(
    request(),
    deps(cache, async () => new Response(bad)),
  );
  equal(response.status, 503, "upstream mismatch");
  equal(cache.body, null, "mismatched data is not cached");
});

Deno.test("cache failure fails closed before reaching GitHub", async () => {
  const cache = new SharedCache(Date.now);
  cache.claim = async () => {
    throw new Error("database down");
  };
  let calls = 0;
  const response = await handleRelease(
    request(),
    deps(cache, async () => {
      calls++;
      return new Response(release);
    }),
  );
  equal(response.status, 503, "cache failure");
  equal(calls, 0, "no GitHub call");
});

Deno.test("rejects methods other than GET", async () => {
  const response = await handleRelease(
    new Request("https://relay.test/release", { method: "POST" }),
    deps(new SharedCache(Date.now), async () => new Response(release)),
  );
  equal(response.status, 405, "method status");
  assert(
    response.headers.has("X-Release-Repository"),
    "repository header on errors",
  );
});
