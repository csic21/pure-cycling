// The routing relay: the AMap key never leaves the server.
//
// ## Why this exists
//
// A rider's phone sends what it sends, and the device owner can read it —
// no decompiling required, just a proxy on their own machine. So a Web
// service key baked into the app is a public key, and AMap's defences do not
// help on mobile: IP allow-lists do not survive a changing mobile IP, and a
// signed request (sig) only ships the secret alongside the key.
//
// So the key lives here, in the function's environment, and the app calls
// this endpoint with its own Supabase session.
//
// ## What it is not
//
// Not a general gateway. It takes exactly two coordinates and calls exactly
// one AMap endpoint — `/v5/direction/bicycling`. Any parameter that could
// point AMap somewhere else is not accepted, because "the relay can call
// anything" is the same quota problem as a leaked key, only politer.
//
// ## The response
//
// AMap's own JSON, passed through. The app already parses that shape and has
// tests against recorded responses; inventing a second contract here would
// mean maintaining two parsers for one vendor. Our own failures (auth, quota,
// bad input) reuse AMap's envelope (`status: "0"`, `info`, `infocode`) so the
// client has one error path.
//
// Deploy:
//   supabase functions deploy route
//   supabase secrets set AMAP_KEY=...
//
// Local:
//   supabase functions serve --env-file supabase/functions/.env

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const AMAP_KEY = Deno.env.get('AMAP_KEY') ?? '';

// Overridable so the verification script can point it at a stub instead of
// the vendor. Production never sets it.
const AMAP_BASE = Deno.env.get('AMAP_BASE_URL') ?? 'https://restapi.amap.com';

// Per account, per day. The project's own free quota is 150,000 calls/month
// for route planning; this keeps one account from being the reason it runs out.
const DAILY_LIMIT = Number(Deno.env.get('ROUTE_DAILY_LIMIT') ?? '200');

const COORDINATE = /^-?\d{1,3}(\.\d+)?,-?\d{1,3}(\.\d+)?$/;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== 'POST') {
    return refusal(405, '只接受 POST');
  }
  if (!AMAP_KEY && AMAP_BASE.includes('amap.com')) {
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

  const origin = String(payload.origin ?? '');
  const destination = String(payload.destination ?? '');
  if (!COORDINATE.test(origin) || !COORDINATE.test(destination)) {
    return refusal(400, 'origin / destination 需要 "lng,lat" 格式');
  }

  const alternatives = Math.min(
    Math.max(Number(payload.alternatives) || 1, 1),
    3,
  );

  // The platform verifies the JWT signature before this runs (verify_jwt is
  // on for this function). We still ask the auth server who it is: identity
  // is the thing the quota hangs on, and "the platform did it" is one
  // configuration change away from being false.
  const userId = await verifiedUserId(req);
  if (userId === null) {
    return refusal(401, '需要登录后使用在线路线规划（匿名账号也可以）');
  }

  const verdict = await consumeQuota(userId);
  if (verdict === 'unavailable') {
    // Distinct from "exhausted" on purpose: the counter being down is our
    // problem, and telling the rider their quota is gone would be a lie.
    return refusal(503, '配额服务暂时不可用，请稍后再试');
  }
  if (verdict === 'exhausted') {
    return refusal(429, `今日在线路线规划次数已用完（上限 ${DAILY_LIMIT} 次）`);
  }

  const url = new URL(`${AMAP_BASE}/v5/direction/bicycling`);
  url.searchParams.set('origin', origin);
  url.searchParams.set('destination', destination);
  // Without show_fields the v5 response omits the polyline entirely.
  url.searchParams.set('show_fields', 'cost,polyline,navi');
  url.searchParams.set('alternative_route', String(alternatives));
  url.searchParams.set('key', AMAP_KEY);

  try {
    const upstream = await fetch(url);
    return new Response(await upstream.text(), {
      status: upstream.status,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    });
  } catch {
    return refusal(502, '无法连接高德服务');
  }
});

/// Resolves the caller through the real auth server, or null.
async function verifiedUserId(req: Request): Promise<string | null> {
  const authorization = req.headers.get('Authorization') ?? '';
  if (!authorization.startsWith('Bearer ') || SUPABASE_URL === '') {
    return null;
  }

  try {
    const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: ANON_KEY, Authorization: authorization },
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
async function consumeQuota(userId: string): Promise<
  'allowed' | 'exhausted' | 'unavailable'
> {
  if (SERVICE_KEY === '') return 'unavailable';

  try {
    const response = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/consume_rate_limit`,
      {
        method: 'POST',
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          p_user_id: userId,
          p_bucket: 'route',
          p_limit: DAILY_LIMIT,
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
