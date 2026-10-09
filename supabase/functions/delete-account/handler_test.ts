import { handleDeleteAccount } from './handler.ts';
import { handleWipeCloudData } from '../wipe-cloud-data/handler.ts';
import {
  type CleanupDeps,
  type CleanupEnv,
  type FetchLike,
} from '../_shared/account-cleanup.ts';

const user = '11111111-1111-7111-8111-111111111111';
const other = '99999999-9999-7999-8999-999999999999';
const prefix = `rides/${user}/`;
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown): void {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${JSON.stringify(actual)} != ${JSON.stringify(expected)}`,
  );
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status });
}
function request(
  body: unknown = {},
  method = 'POST',
  token: string | null = 'session',
) {
  return new Request('https://project.test/functions/v1/delete-account', {
    method,
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    body: method === 'POST' ? JSON.stringify(body) : undefined,
  });
}

type StubOptions = {
  paths?: string[];
  env?: Partial<CleanupEnv>;
  authStatus?: number;
  authId?: string;
  failAt?: string;
  failDeleteBatch?: number;
  invalidList?: unknown;
  noProgress?: boolean;
  lateObject?: boolean;
};
function stub(options: StubOptions = {}) {
  const calls: string[] = [];
  const storage = new Set(
    options.paths ?? [
      `${prefix}ride-1/original.gpx`,
      `${prefix}orphan/attempt-1.gpx`,
      `${prefix}nested/orphan/attempt-2.gpx`,
    ],
  );
  let fenced = false;
  let mode = '';
  let batches = 0;
  let lists = 0;
  const deleted: string[] = [];
  const rpcBodies: Record<string, unknown>[] = [];
  const deps: CleanupDeps = {
    env: {
      supabaseUrl: 'https://project.test',
      anonKey: 'anon',
      serviceKey: 'service',
      ...options.env,
    },
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      const name = url.pathname.split('/').pop()!;
      calls.push(name);
      if (url.pathname === '/auth/v1/user') {
        return json({ id: options.authId ?? user }, options.authStatus ?? 200);
      }
      if (name === options.failAt) {
        return json({
          code: name === 'begin_account_cleanup' ? '55P03' : 'error',
        }, 500);
      }
      const body = init?.body ? JSON.parse(String(init.body)) : {};
      if (url.pathname.startsWith('/rest/v1/rpc/')) {
        rpcBodies.push(body);
        equal(body.p_user_id, user);
        assert(typeof body.p_token === 'string', 'cleanup must hold a token');
      }
      if (name === 'begin_account_cleanup') {
        equal(body.p_actor_id, user);
        fenced = true;
        mode = body.p_mode;
        return json(null);
      }
      if (name === 'list_account_cleanup_objects') {
        assert(fenced, 'must fence before enumerating storage');
        lists++;
        if (options.invalidList !== undefined) return json(options.invalidList);
        if (options.lateObject && lists === 2) {
          storage.add(`${prefix}late/upload.gpx`);
        }
        return json(
          [...storage].sort().slice(0, 500).map((name) => ({ name })),
        );
      }
      if (url.pathname === '/storage/v1/object/rides') {
        assert(fenced, 'must fence before deleting storage');
        equal(init?.method, 'DELETE');
        assert(body.prefixes.length <= 100, 'batch limit');
        batches++;
        if (batches === options.failDeleteBatch) {
          return json({ error: 'storage failed' }, 500);
        }
        for (const path of body.prefixes) {
          assert(
            path.startsWith(prefix),
            'must never delete another user file',
          );
          deleted.push(path);
          if (!options.noProgress) storage.delete(path);
        }
        return json([]);
      }
      if (name === 'finish_account_cleanup') {
        assert(
          storage.size === 0,
          'storage must really be empty before finishing',
        );
        if (mode === 'wipe') fenced = false;
        return json(null);
      }
      if (name === 'release_account_cleanup') {
        assert(fenced, 'a failed cleanup must keep its durable fence');
        return json(null);
      }
      if (url.pathname === `/auth/v1/admin/users/${user}`) {
        assert(
          fenced && storage.size === 0,
          'account deletion requires empty fenced storage',
        );
        assert(
          calls.includes('finish_account_cleanup'),
          'database must verify empty storage',
        );
        return json({});
      }
      throw new Error(`unexpected request ${url}`);
    }) as FetchLike,
  };
  return { deps, calls, storage, deleted, rpcBodies };
}

Deno.test('method, session and configuration refusals have no cleanup side effects', async () => {
  for (
    const [req, options, status] of [
      [request({}, 'GET'), {}, 405],
      [request({}, 'POST', null), {}, 401],
      [request(), { authStatus: 401 }, 401],
      [request(), { authId: '../other' }, 401],
      [request(), { env: { serviceKey: '' } }, 503],
    ] as const
  ) {
    const run = stub(options);
    equal((await handleDeleteAccount(req, run.deps)).status, status);
    assert(
      !run.calls.includes('begin_account_cleanup'),
      'must not claim cleanup',
    );
  }
});

Deno.test('deletes orphan, versioned and nested files before account, ignoring body identity', async () => {
  const run = stub();
  const response = await handleDeleteAccount(
    request({ user_id: other, id: other }),
    run.deps,
  );
  equal(response.status, 200);
  equal(await response.json(), { deleted: true, files: 3 });
  equal(run.calls.at(-1), user);
  equal(run.storage.size, 0);
});

Deno.test('fully drains >1000 objects without offset pagination skips', async () => {
  const run = stub({
    paths: Array.from({ length: 1203 }, (_, i) => `${prefix}${i}/attempt.gpx`),
  });
  const response = await handleDeleteAccount(request(), run.deps);
  equal(response.status, 200);
  equal(await response.json(), { deleted: true, files: 1203 });
  equal(run.deleted.length, 1203);
  equal(
    run.calls.filter((name) => name === 'list_account_cleanup_objects').length,
    4,
  );
});

Deno.test('a late visible upload is drained before completion', async () => {
  const run = stub({ lateObject: true });
  const response = await handleDeleteAccount(request(), run.deps);
  equal(await response.json(), { deleted: true, files: 4 });
});

Deno.test('cleanup failures never delete user and retain retry fence', async () => {
  for (
    const options of [
      { failAt: 'list_account_cleanup_objects' },
      {
        failDeleteBatch: 2,
        paths: Array.from(
          { length: 150 },
          (_, i) => `${prefix}${i}/original.gpx`,
        ),
      },
      { failAt: 'finish_account_cleanup' },
      { noProgress: true },
      { invalidList: {} },
      { invalidList: [{ name: `rides/${other}/original.gpx` }] },
      { invalidList: [{ name: `rides/${user}-suffix/original.gpx` }] },
      { invalidList: [{ name: `${prefix}../victim/original.gpx` }] },
    ]
  ) {
    const run = stub(options);
    equal((await handleDeleteAccount(request(), run.deps)).status, 502);
    assert(!run.calls.includes(user), 'user must survive failed cleanup');
    equal(run.calls.at(-1), 'release_account_cleanup');
  }
});

Deno.test('partial removal can be retried from authoritative remaining objects', async () => {
  const run = stub({
    failDeleteBatch: 2,
    paths: Array.from({ length: 150 }, (_, i) => `${prefix}${i}/original.gpx`),
  });
  equal((await handleDeleteAccount(request(), run.deps)).status, 502);
  equal(run.storage.size, 50);
  const response = await handleDeleteAccount(request(), run.deps);
  equal(response.status, 200);
  equal(await response.json(), { deleted: true, files: 50 });
});

Deno.test('concurrent claim returns conflict and never releases someone else lease', async () => {
  const run = stub({ failAt: 'begin_account_cleanup' });
  equal((await handleDeleteAccount(request(), run.deps)).status, 409);
  assert(
    !run.calls.includes('release_account_cleanup'),
    'cannot release another worker',
  );
  assert(
    !run.calls.includes('list_account_cleanup_objects'),
    'cannot enumerate without claim',
  );
});

Deno.test('auth deletion failure is not success; empty-storage retry is safe', async () => {
  const run = stub({ failAt: user });
  equal((await handleDeleteAccount(request(), run.deps)).status, 502);
  equal(run.storage.size, 0);
  equal(run.calls.at(-1), 'release_account_cleanup');
});

Deno.test('cloud wipe uses the same orphan cleanup, keeps account, clears only on verified finish', async () => {
  const run = stub();
  const response = await handleWipeCloudData(
    request({ user_id: other }),
    run.deps,
  );
  equal(response.status, 200);
  equal(await response.json(), { wiped: true, files: 3 });
  equal(run.rpcBodies[0].p_mode, 'wipe');
  equal(run.calls.at(-1), 'finish_account_cleanup');
  assert(!run.calls.includes(user), 'cloud wipe must not delete account');
});

Deno.test('cloud wipe refuses unauthenticated/method failures and reports incomplete cleanup', async () => {
  equal(
    (await handleWipeCloudData(request({}, 'GET'), stub().deps)).status,
    405,
  );
  equal(
    (await handleWipeCloudData(request({}, 'POST', null), stub().deps)).status,
    401,
  );
  const run = stub({ failAt: 'finish_account_cleanup' });
  equal((await handleWipeCloudData(request(), run.deps)).status, 502);
  equal(run.calls.at(-1), 'release_account_cleanup');
});
