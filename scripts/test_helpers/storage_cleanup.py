"""Disposable real Storage regression fixtures; never a hosted-project client."""
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

WORK = Path(os.environ['STORAGE_TEST_WORK'])
AUTH = os.environ['STORAGE_TEST_AUTH_URL']
STORAGE = os.environ['STORAGE_TEST_URL']
DB = os.environ['STORAGE_TEST_DB']
assert AUTH.startswith('http://127.0.0.1:') and STORAGE.startswith('http://127.0.0.1:')
KEYS = json.loads((WORK / 'keys.json').read_text())
GPX = b'<?xml version="1.0"?><gpx version="1.1"><trk><name>fixture</name></trk></gpx>'


def http(url, token=None, data=None, method='GET', content_type='application/json', headers=None):
    h = {'Content-Type': content_type, **(headers or {})}
    if token:
        h['Authorization'] = f'Bearer {token}'
    request = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def sql(statement):
    result = subprocess.run(
        ['docker', 'exec', '-i', DB, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq'],
        input=statement, text=True, capture_output=True, check=True)
    return result.stdout.strip()


def upload(path, token, payload=GPX, upsert=False):
    return http(f'{STORAGE}/object/rides/{path}', token, payload, 'POST',
                'application/gpx+xml', {'x-upsert': str(upsert).lower()})


def download(path, token):
    return http(f'{STORAGE}/object/authenticated/rides/{path}', token)


def new_path(user):
    ride, attempt = str(uuid.uuid4()), str(uuid.uuid4())
    return sql(f"begin; set local role authenticated; set local request.jwt.claim.sub = '{user['id']}'; "
               f"select public.new_gpx_upload_path('{ride}', '{attempt}'); commit;").splitlines()[-1]


def success(response, purpose):
    assert 200 <= response[0] < 300, f'{purpose}: HTTP {response[0]} {response[1][:300]!r}'


def seed():
    users = []
    for _ in range(2):
        body = json.dumps({'email': f'storage-{uuid.uuid4()}@example.com', 'password': 'local-fixture-only-pass'}).encode()
        status, result = http(f'{AUTH}/signup', data=body, method='POST')
        assert status == 200, f'local signup failed: HTTP {status}'
        result = json.loads(result)
        user = {'id': result['user']['id'], 'token': result['access_token']}
        uuid.UUID(user['id'])
        user['legacy'] = f"rides/{user['id']}/{uuid.uuid4()}/original.gpx"
        success(upload(user['legacy'], user['token']), 'normal legacy HTTP upload control')
        assert download(user['legacy'], user['token']) == (200, GPX), 'normal file backend/xattr control failed'
        users.append(user)
    (WORK / 'users.json').write_text(json.dumps(users))
    print('  ✓ real Auth sessions and successful pre-migration Storage upload/download controls')


def paths_on_disk(object_path):
    # File backend lays out tenant/bucket/object-name/version. Match the exact
    # logical name plus a separator/version suffix, not another user's prefix.
    return [p for p in (WORK / 'storage').rglob('*')
            if p.is_file() and f'/{object_path}' in str(p) and p.stat().st_size > 0]


def overlap(user, mode):
    path = new_path(user)
    released = threading.Event()
    started = threading.Event()
    outcome = []
    payload = GPX + b' ' * (1024 * 1024)

    def stream():
        connection = http.client.HTTPConnection(urllib.parse.urlsplit(STORAGE).netloc, timeout=90)
        try:
            connection.putrequest('POST', f'/object/rides/{path}')
            connection.putheader('Authorization', f"Bearer {user['token']}")
            connection.putheader('Content-Type', 'application/gpx+xml')
            connection.putheader('Content-Length', str(len(payload)))
            connection.putheader('x-upsert', 'false')
            connection.endheaders()
            connection.send(payload[:65536])
            started.set()
            assert released.wait(60), 'controller never released the upload stream'
            connection.send(payload[65536:])
            response = connection.getresponse()
            outcome.append((response.status, response.read()))
        except BaseException as error:
            outcome.append(error)
        finally:
            connection.close()

    worker = threading.Thread(target=stream, daemon=True)
    worker.start()
    raw_files = []
    try:
        assert started.wait(10), 'HTTP stream did not start'
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            raw_files = paths_on_disk(path)
            if raw_files:
                break
            if outcome:
                raise AssertionError(f'upload failed before streaming barrier: {outcome!r}')
            time.sleep(0.05)
        assert raw_files, 'no partial raw file: cannot prove RLS preflight passed'
        assert not outcome, 'upload completed before cleanup barrier'
        assert sql(f"select count(*) from storage.objects where bucket_id='rides' and name='{path}';") == '0'
        print(f'  ✓ {mode}: observed nonzero raw version bytes after preflight, before metadata commit')

        token = str(uuid.uuid4())
        sql(f"select public.begin_account_cleanup('{user['id']}', '{user['id']}', '{mode}', '{token}');")
        # The stream remains paused. Drain only authoritative committed objects;
        # the in-flight version is deliberately invisible to metadata enumeration.
        while True:
            listed = sql(f"select name from public.list_account_cleanup_objects('{user['id']}', '{token}');")
            if not listed:
                break
            names = listed.splitlines()
            assert all(name.startswith(f"rides/{user['id']}/") for name in names)
            response = http(f'{STORAGE}/object/rides', KEYS['service'],
                            json.dumps({'prefixes': names}).encode(), 'DELETE')
            success(response, 'Storage API removal')
        sql(f"select public.finish_account_cleanup('{user['id']}', '{token}');")
        if mode == 'delete':
            success(http(f"{AUTH}/admin/users/{user['id']}", KEYS['service'], method='DELETE'), 'local Auth account deletion')
        released.set()
        worker.join(30)
        assert not worker.is_alive(), 'slow upload did not finish after release'
        assert len(outcome) == 1 and isinstance(outcome[0], tuple), f'no HTTP rejection evidence: {outcome!r}'
        assert outcome[0][0] >= 400, f'pre-cleanup upload resurrected: HTTP {outcome[0][0]}'
        assert sql(f"select count(*) from storage.objects where bucket_id='rides' and name='{path}';") == '0'
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and any(p.exists() for p in raw_files):
            time.sleep(0.1)
        assert not any(p.exists() for p in raw_files), 'rejected upload left underlying version bytes behind'
        print(f'  ✓ {mode}: privileged finalization rejected, no metadata and raw version bytes reclaimed')
    finally:
        released.set()
        worker.join(35)


def verify():
    owner, other = json.loads((WORK / 'users.json').read_text())
    assert download(owner['legacy'], owner['token']) == (200, GPX), 'legacy committed file no longer readable'
    assert upload(owner['legacy'], owner['token'], b'replacement', upsert=True)[0] >= 400, 'legacy overwrite still allowed'
    assert download(owner['legacy'], owner['token']) == (200, GPX), 'rejected legacy overwrite damaged winner'
    fresh = new_path(owner)
    success(upload(fresh, owner['token']), 'current-epoch upload')
    assert upload(fresh, owner['token'], b'replacement', upsert=True)[0] >= 400, 'versioned object was overwritten'
    assert download(fresh, owner['token']) == (200, GPX)
    assert download(other['legacy'], owner['token'])[0] >= 400, 'cross-account read leaked'
    print('  ✓ current-epoch upload succeeds; legacy reads and immutable bytes preserved; cross-user reads blocked')

    overlap(owner, 'wipe')
    fresh = new_path(owner)
    success(upload(fresh, owner['token']), 'new epoch after wipe')
    assert download(fresh, owner['token']) == (200, GPX)
    assert download(other['legacy'], other['token']) == (200, GPX), 'wipe affected another user'
    print('  ✓ new uploads work after wipe; other user unchanged')
    overlap(owner, 'delete')
    assert download(other['legacy'], other['token']) == (200, GPX), 'account deletion affected another user'
    print('  ✓ account deletion leaves other user unchanged')


if __name__ == '__main__':
    {'seed': seed, 'verify': verify}[sys.argv[1]]()
