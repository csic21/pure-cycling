// The account-deletion handler, with the network stubbed.
//
// What matters here is not the happy path alone but the things that would make
// deletion a lie or a weapon: deleting before the objects (orphaned location
// traces), being pointed at somebody else's account, and reporting success
// when the account is still there.

import {
  handleDeleteAccount,
  type DeleteDeps,
  type DeleteEnv,
  type FetchLike,
} from './handler.ts';

function assert(condition: unknown, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${message}（得到 ${a}，期望 ${b}）`);
}

type Stub = {
  env?: Partial<DeleteEnv>;
  auth?: () => Response | Promise<Response>;
  rides?: (url: URL) => Response | Promise<Response>;
  objects?: () => Response | Promise<Response>;
  user?: () => Response | Promise<Response>;
  calls?: string[];
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function deps(stub: Stub = {}): DeleteDeps {
  const env: DeleteEnv = {
    supabaseUrl: 'https://project.test',
    anonKey: 'anon-key',
    serviceKey: 'service-key',
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
      return stub.auth ? await stub.auth() : json({ id: 'user-1' });
    }
    if (url.pathname === '/rest/v1/rides') {
      stub.calls?.push('list-objects');
      return stub.rides
        ? await stub.rides(url)
          : json([
            { id: 'ride-1', gpx_path: 'rides/user-1/ride-1/original.gpx' },
            { id: 'ride-2', gpx_path: 'rides/user-1/ride-2/original.gpx' },
          ]);
    }
    if (url.pathname === '/storage/v1/object/rides') {
      stub.calls?.push('delete-objects');
      return stub.objects ? await stub.objects() : json([]);
    }
    if (url.pathname.startsWith('/auth/v1/admin/users/')) {
      stub.calls?.push(`delete-user:${url.pathname.split('/').pop()}`);
      return stub.user ? await stub.user() : json({});
    }

    throw new Error(`unexpected request to ${url}`);
  };

  return { fetch: fetchImpl as FetchLike, env };
}

function request(
  body: unknown = {},
  { token = 'session', method = 'POST' }: { token?: string | null; method?: string } = {},
): Request {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token !== null) headers['Authorization'] = `Bearer ${token}`;
  return new Request('https://project.test/functions/v1/delete-account', {
    method,
    headers,
    body: method === 'POST' ? JSON.stringify(body) : undefined,
  });
}

Deno.test('POST only', async () => {
  const response = await handleDeleteAccount(
    request({}, { method: 'GET' }),
    deps(),
  );
  assertEquals(response.status, 405, 'GET 应该是 405');
});

Deno.test('without a session', async () => {
  const response = await handleDeleteAccount(request({}, { token: null }), deps());
  assertEquals(response.status, 401, '没有会话就是 401');
});

Deno.test('a session the auth server rejects', async () => {
  const response = await handleDeleteAccount(
    request(),
    deps({ auth: () => json({ message: 'invalid' }, 401) }),
  );
  assertEquals(response.status, 401, 'auth 服务拒绝就是 401');
});

Deno.test('no service key means the deletion cannot be attempted', async () => {
  const response = await handleDeleteAccount(
    request(),
    deps({ env: { serviceKey: '' } }),
  );
  assertEquals(response.status, 503, '没有 service key 是 503');
});

Deno.test('objects are deleted before the account', async () => {
  const calls: string[] = [];
  const response = await handleDeleteAccount(request(), deps({ calls }));

  assertEquals(response.status, 200, '正常删除是 200');
  assertEquals(await response.json(), { deleted: true, files: 2 }, '计数只算真删掉的');
  assertEquals(
    calls[0],
    'list-objects',
    '先读路径：行是桶内容的索引，删了行就找不到文件',
  );
  assertEquals(calls[1], 'delete-objects', '再删对象');
  assertEquals(calls[2], 'delete-user:user-1', '最后删账号（行随级联走）');
});

Deno.test('the body cannot name somebody else', async () => {
  const calls: string[] = [];
  await handleDeleteAccount(
    request({ user_id: 'victim', id: 'victim', email: 'victim@example.com' }),
    deps({ calls }),
  );

  assertEquals(
    calls.filter((c) => c.startsWith('delete-user:')),
    ['delete-user:user-1'],
    '删除的永远是会话本人，参数改不了它',
  );
});

Deno.test('a failed account deletion is reported as a failure', async () => {
  const response = await handleDeleteAccount(
    request(),
    deps({ user: () => json({ message: 'boom' }, 500) }),
  );
  assertEquals(response.status, 502, '账号没删掉就不能说成功');
  const body = await response.json();
  assertEquals(typeof body.error, 'string', '带上原因');
});

Deno.test('storage trouble keeps the account so deletion can be retried', async () => {
  const calls: string[] = [];
  const response = await handleDeleteAccount(
    request(),
    deps({ objects: () => json({ message: 'storage down' }, 500), calls }),
  );
  assertEquals(response.status, 502, '文件未删完就不能报告成功');
  assert(!calls.includes('delete-user:user-1'), '账号要保留，以便重试');
});

Deno.test('a failed rides query keeps the account and its GPX index', async () => {
  const calls: string[] = [];
  const response = await handleDeleteAccount(
    request(),
    deps({ rides: () => json({ message: 'nope' }, 500), calls }),
  );
  assertEquals(response.status, 502, '查不到文件路径不能声称删除完成');
  assert(
    !calls.includes('delete-user:user-1'),
    '账号和骑行索引要保留，以便重试',
  );
});

Deno.test('a forged GPX path cannot delete another account\'s file', async () => {
  const calls: string[] = [];
  const response = await handleDeleteAccount(
    request(),
    deps({
      rides: () => json([{
        id: 'ride-1',
        gpx_path: 'rides/victim/ride-1/original.gpx',
      }]),
      calls,
    }),
  );
  assertEquals(response.status, 502, '路径与账号不符就拒绝');
  assert(!calls.includes('delete-objects'), '不能用 service role 删除伪造的路径');
  assert(!calls.includes('delete-user:user-1'), '账号仍然存在');
});

Deno.test('lists every GPX path beyond the first PostgREST page', async () => {
  const calls: string[] = [];
  const response = await handleDeleteAccount(
    request(),
    deps({
      rides: (url) => {
        const offset = Number(url.searchParams.get('offset'));
        const count = offset === 0 ? 500 : 1;
        return json(Array.from({ length: count }, (_, index) => {
          const id = `ride-${offset + index}`;
          return { id, gpx_path: `rides/user-1/${id}/original.gpx` };
        }));
      },
      calls,
    }),
  );
  assertEquals(response.status, 200, '所有路径删除后才删账号');
  assertEquals(await response.json(), { deleted: true, files: 501 }, '不漏掉第二页');
  assertEquals(calls.filter((call) => call === 'list-objects').length, 2, '读取两页');
  assertEquals(calls.filter((call) => call === 'delete-objects').length, 6, '分批删除');
});
