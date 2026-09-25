// The routing relay's logic, with everything external injected.
//
// `index.ts` is the Deno wiring around this; keeping the logic here means it
// runs on every push under `deno test` — no vendor key, no Edge runtime, no
// network. `verify-routing-relay.sh` covers the other half (the real function
// served by the real runtime, against a stub vendor).
//
// ## Why the relay exists
//
// A rider's phone sends what it sends, and the device owner can read it — no
// decompiling required, just a proxy on their own machine. So a Web service
// key baked into the app is a public key, and AMap's defences do not help on
// mobile: IP allow-lists do not survive a changing mobile IP, and a signed
// request (sig) only ships the secret alongside the key. The key lives in the
// function's environment instead.
//
// ## What it is not
//
// Not a general gateway. It takes exactly two coordinates and calls exactly
// one AMap endpoint. "The relay can call anything" is the same quota problem
// as a leaked key, only politer.
//
// ## The response
//
// AMap's own JSON, passed through: the app already parses that shape and has
// tests against recorded responses. Our own failures reuse the envelope
// (`status: "0"`, `info`, `infocode`) so the client keeps one error path.

export interface RelayEnv {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
  amapKey: string;
  amapBase: string;
  dailyLimit: number;
}

/// `typeof fetch` cannot be written where a parameter is also called
/// `fetch` — the type refers to the parameter and TS rejects the cycle.
export type FetchLike = typeof globalThis.fetch;

export interface RelayDeps {
  fetch: FetchLike;
  env: RelayEnv;
}

const COORDINATE = /^-?\d{1,3}(\.\d+)?,-?\d{1,3}(\.\d+)?$/;

export async function handleRoute(
  req: Request,
  { fetch: fetchImpl, env }: RelayDeps,
): Promise<Response> {
  if (req.method !== 'POST') {
    return refusal(405, '只接受 POST');
  }
  if (!env.amapKey && env.amapBase.includes('amap.com')) {
    return refusal(503, '服务端没有配置高德 Key');
  }

  let payload: {
    origin?: unknown;
    destination?: unknown;
    alternatives?: unknown;
  };
  try {
    payload = await req.json();
  } catch {
    return refusal(400, '请求体不是合法 JSON');
  }

  // Only these three fields are read. A `key` in the body would do nothing —
  // the vendor credential is not a parameter here, which is the whole point.
  const origin = String(payload.origin ?? '');
  const destination = String(payload.destination ?? '');
  if (!COORDINATE.test(origin) || !COORDINATE.test(destination)) {
    return refusal(400, 'origin / destination 需要 "lng,lat" 格式');
  }

  const alternatives = Math.min(
    Math.max(Number(payload.alternatives) || 1, 1),
    3,
  );

  const userId = await verifiedUserId(req, fetchImpl, env);
  if (userId === null) {
    return refusal(401, '需要登录后使用在线路线规划（匿名账号也可以）');
  }

  const verdict = await consumeQuota(userId, fetchImpl, env);
  if (verdict === 'unavailable') {
    // Distinct from "exhausted" on purpose: the counter being down is our
    // problem, and telling the rider their quota is gone would be a lie.
    return refusal(503, '配额服务暂时不可用，请稍后再试');
  }
  if (verdict === 'exhausted') {
    return refusal(429, `今日在线路线规划次数已用完（上限 ${env.dailyLimit} 次）`);
  }

  const url = new URL(`${env.amapBase}/v5/direction/bicycling`);
  url.searchParams.set('origin', origin);
  url.searchParams.set('destination', destination);
  // Without show_fields the v5 response omits the polyline entirely.
  url.searchParams.set('show_fields', 'cost,polyline,navi');
  url.searchParams.set('alternative_route', String(alternatives));
  url.searchParams.set('key', env.amapKey);

  try {
    const upstream = await fetchImpl(url);
    return new Response(await upstream.text(), {
      status: upstream.status,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    });
  } catch {
    return refusal(502, '无法连接高德服务');
  }
}

/// Resolves the caller through the real auth server, or null.
///
/// The platform already verifies the JWT signature before this runs
/// (`verify_jwt` is on for this function). We ask the auth server anyway:
/// identity is what the quota hangs on, and "the platform did it" is one
/// configuration change away from being false.
async function verifiedUserId(
  req: Request,
  fetchImpl: FetchLike,
  env: RelayEnv,
): Promise<string | null> {
  const authorization = req.headers.get('Authorization') ?? '';
  if (!authorization.startsWith('Bearer ') || env.supabaseUrl === '') {
    return null;
  }

  try {
    const response = await fetchImpl(`${env.supabaseUrl}/auth/v1/user`, {
      headers: { apikey: env.anonKey, Authorization: authorization },
    });
    if (!response.ok) return null;
    const user = await response.json();
    return typeof user?.id === 'string' ? user.id : null;
  } catch {
    return null;
  }
}

/// One unit of today's quota for this account.
///
/// Three outcomes, not two: "allowed", "exhausted" and "the counter is
/// unreachable". The last one fails closed — a broken counter must not become
/// an open relay — but it must not be reported as the rider's quota being
/// gone either.
async function consumeQuota(
  userId: string,
  fetchImpl: FetchLike,
  env: RelayEnv,
): Promise<'allowed' | 'exhausted' | 'unavailable'> {
  if (env.serviceKey === '') return 'unavailable';

  try {
    const response = await fetchImpl(
      `${env.supabaseUrl}/rest/v1/rpc/consume_rate_limit`,
      {
        method: 'POST',
        headers: {
          apikey: env.serviceKey,
          Authorization: `Bearer ${env.serviceKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          p_user_id: userId,
          p_bucket: 'route',
          p_limit: env.dailyLimit,
          p_window_seconds: 86400,
        }),
      },
    );
    if (!response.ok) return 'unavailable';
    return (await response.json()) === true ? 'allowed' : 'exhausted';
  } catch {
    return 'unavailable';
  }
}

/// Our own failures, in AMap's envelope so the client keeps one error path.
function refusal(status: number, message: string): Response {
  return new Response(
    JSON.stringify({
      status: '0',
      info: message,
      infocode: `relay_${status}`,
    }),
    {
      status,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    },
  );
}
