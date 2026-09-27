// The relay's logic, with the network stubbed. No vendor key, no Edge runtime,
// no Docker — this is the part that runs on every push in CI.
//
// The other half is `scripts/verify-routing-relay.sh`, which serves the real
// function against a stub vendor. What is here is what that harness cannot
// cheaply reach: the refusals, the quota verdicts, and what exactly the relay
// asks the vendor for.

import {
  handleRoute,
  type FetchLike,
  type RelayDeps,
  type RelayEnv,
} from './handler.ts';

// Deno's std assert is a remote import; these three lines keep the test
// hermetic, which matters more than fancy matchers for a file this size.
function assert(condition: unknown, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${message}（得到 ${a}，期望 ${b}）`);
}

type Stub = {
  env?: Partial<RelayEnv>;
  auth?: () => Response | Promise<Response>;
  quota?: (body: { p_bucket: string; p_limit: number }) => Response | Promise<Response>;
  amap?: (url: URL) => Response | Promise<Response>;
  record?: { amapUrl?: URL; authorization?: string | null };
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function deps(stub: Stub = {}): RelayDeps {
  const env: RelayEnv = {
    supabaseUrl: 'https://project.test',
    anonKey: 'anon-key',
    serviceKey: 'service-key',
    amapKey: 'server-key',
    amapBase: 'https://amap.test',
    dailyLimit: 200,
    globalDailyLimit: 500,
    ...stub.env,
  };

  const fetchImpl = async (
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = new URL(
      typeof input === 'string'
        ? input
        : input instanceof URL
          ? input.toString()
          : input.url,
    );

    if (url.pathname === '/auth/v1/user') {
      if (stub.record) {
        stub.record.authorization = new Headers(init?.headers).get(
          'Authorization',
        );
      }
      return stub.auth ? await stub.auth() : json({ id: 'user-1' });
    }
    if (url.pathname === '/rest/v1/rpc/consume_rate_limit') {
      return stub.quota
        ? await stub.quota(JSON.parse(init?.body as string))
        : json(true);
    }

    if (stub.record) stub.record.amapUrl = url;
    return stub.amap
      ? await stub.amap(url)
      : json({ status: '1', info: 'OK', route: { paths: [{ steps: [] }] } });
  };

  return { fetch: fetchImpl as FetchLike, env };
}

function relayRequest(
  body: unknown = {
    origin: '116.4074,39.9042',
    destination: '116.4174,39.9142',
  },
  { token = 'session', method = 'POST' }: { token?: string | null; method?: string } = {},
): Request {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  if (token !== null) headers['Authorization'] = `Bearer ${token}`;
  return new Request('https://project.test/functions/v1/route', {
    method,
    headers,
    body: method === 'POST'
      ? typeof body === 'string'
        ? body
        : JSON.stringify(body)
      : undefined,
  });
}

async function envelope(response: Response): Promise<Record<string, unknown>> {
  return JSON.parse(await response.text());
}

Deno.test('POST only', async () => {
  const response = await handleRoute(relayRequest(undefined, { method: 'GET' }), deps());
  assertEquals(response.status, 405, 'GET 应该是 405');
});

Deno.test('a body that is not JSON', async () => {
  const response = await handleRoute(relayRequest('not json'), deps());
  assertEquals(response.status, 400, '坏 JSON 应该是 400');
});

Deno.test('coordinates that are not coordinates', async () => {
  const response = await handleRoute(
    relayRequest({ origin: '北京', destination: '116.4174,39.9142' }),
    deps(),
  );
  assertEquals(response.status, 400, '坏坐标应该是 400');
});

Deno.test('without a session', async () => {
  const response = await handleRoute(relayRequest(undefined, { token: null }), deps());
  assertEquals(response.status, 401, '没有会话应该是 401');
  const body = await envelope(response);
  assertEquals(body.infocode, 'relay_401', '401 也走 AMap 信封');
});

Deno.test('a session the auth server rejects', async () => {
  const response = await handleRoute(
    relayRequest(),
    deps({ auth: () => json({ message: 'invalid token' }, 401) }),
  );
  assertEquals(response.status, 401, 'auth 服务拒绝就是 401');
});

Deno.test('a quota counter that is down fails closed, but says so honestly', async () => {
  const response = await handleRoute(
    relayRequest(),
    deps({ quota: () => json({ message: 'no such function' }, 404) }),
  );
  // The first version of this returned 429 ("quota exhausted") when the RPC
  // was missing. That is a lie, and it sends the rider to check a quota that
  // was never the problem.
  assertEquals(response.status, 503, '计数器不可用是 503，不是 429');
  const body = await envelope(response);
  assertEquals(body.infocode, 'relay_503', '原因写清楚');
});

Deno.test('an exhausted quota', async () => {
  const response = await handleRoute(
    relayRequest(),
    deps({ quota: () => json(false) }),
  );
  assertEquals(response.status, 429, '配额用尽是 429');
  const body = await envelope(response);
  assertEquals(body.infocode, 'relay_429', '走 AMap 信封');
});

Deno.test('the project quota stops new anonymous accounts too', async () => {
  const buckets: string[] = [];
  let vendorCalled = false;
  const response = await handleRoute(
    relayRequest(),
    deps({
      quota: (body) => {
        buckets.push(body.p_bucket);
        return json(body.p_bucket !== 'route-global');
      },
      amap: () => {
        vendorCalled = true;
        return json({});
      },
    }),
  );
  assertEquals(response.status, 429, '项目额度耗尽应拒绝调用');
  assertEquals(buckets, ['route', 'route-global'], '先检查用户，再检查项目总额度');
  assertEquals(vendorCalled, false, '项目额度耗尽时不能请求高德');
});

Deno.test('without a session the vendor is never called', async () => {
  let called = false;
  const response = await handleRoute(
    relayRequest(undefined, { token: null }),
    deps({
      amap: () => {
        called = true;
        return json({});
      },
    }),
  );
  assertEquals(response.status, 401, '401');
  assertEquals(called, false, '拒绝的请求不能消耗配额之外的任何东西');
});

Deno.test('a route request reaches the vendor with the server key', async () => {
  const record: Stub['record'] = {};
  const vendorBody = {
    status: '1',
    info: 'OK',
    route: { paths: [{ steps: [{ instruction: '向东骑行' }] }] },
  };

  const response = await handleRoute(
    relayRequest({ origin: '116.4074,39.9042', destination: '116.4174,39.9142' }),
    deps({ record, amap: () => json(vendorBody) }),
  );

  assertEquals(response.status, 200, '正常请求是 200');
  assertEquals(await response.json(), vendorBody, '响应原样透传');

  const url = record.amapUrl!;
  assertEquals(url.pathname, '/v5/direction/bicycling', '只调用骑行算路');
  assertEquals(url.searchParams.get('origin'), '116.4074,39.9042', '起点透传');
  assertEquals(url.searchParams.get('destination'), '116.4174,39.9142', '终点透传');
  assertEquals(
    url.searchParams.get('show_fields'),
    'cost,polyline,navi',
    '没有 show_fields 就没有几何数据',
  );
  assertEquals(url.searchParams.get('key'), 'server-key', 'Key 由服务端附加');
  assertEquals(
    record.authorization,
    'Bearer session',
    '用调用者的会话向 auth 服务确认身份',
  );
});

Deno.test('a client cannot smuggle its own key or endpoint', async () => {
  const record: Stub['record'] = {};
  await handleRoute(
    relayRequest({
      origin: '116.4074,39.9042',
      destination: '116.4174,39.9142',
      key: 'attacker-key',
      path: '/v3/place/text',
      amapBase: 'https://attacker.test',
    }),
    deps({ record }),
  );

  const url = record.amapUrl!;
  assertEquals(url.host, 'amap.test', '上游主机不能被请求体改变');
  assertEquals(url.pathname, '/v5/direction/bicycling', '路径不能被请求体改变');
  assertEquals(url.searchParams.get('key'), 'server-key', 'Key 不能被请求体覆盖');
});

Deno.test('alternatives are clamped to what the vendor accepts', async () => {
  const record: Stub['record'] = {};
  await handleRoute(
    relayRequest({
      origin: '116.4074,39.9042',
      destination: '116.4174,39.9142',
      alternatives: 99,
    }),
    deps({ record }),
  );
  assertEquals(
    record.amapUrl!.searchParams.get('alternative_route'),
    '3',
    '最多三条备选',
  );
});

Deno.test('a missing key is a configuration error, not a rider error', async () => {
  const response = await handleRoute(
    relayRequest(),
    deps({ env: { amapKey: '', amapBase: 'https://restapi.amap.com' } }),
  );
  assertEquals(response.status, 503, '没配 Key 是服务端问题');
  const body = await envelope(response);
  assertEquals(body.infocode, 'relay_503', '走 AMap 信封');
});

Deno.test('the vendor being unreachable', async () => {
  const response = await handleRoute(
    relayRequest(),
    deps({
      amap: () => {
        throw new Error('connection refused');
      },
    }),
  );
  assertEquals(response.status, 502, '连不上高德是 502');
});
