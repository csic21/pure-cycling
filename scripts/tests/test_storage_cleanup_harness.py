"""Fast checks for harness plumbing, not substitutes for real Storage CI."""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class StorageCleanupHarnessTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        (self.work / 'keys.json').write_text(json.dumps({'service': 'fixture-token'}))
        path = Path(__file__).resolve().parents[1] / 'test_helpers' / 'storage_cleanup.py'
        spec = importlib.util.spec_from_file_location('storage_cleanup_harness', path)
        self.helper = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, {
            'STORAGE_TEST_WORK': str(self.work),
            'STORAGE_TEST_AUTH_URL': 'http://127.0.0.1:55451',
            'STORAGE_TEST_URL': 'http://127.0.0.1:55452',
            'STORAGE_TEST_DB': 'unused-fixture-db',
        }):
            spec.loader.exec_module(self.helper)

    def test_http_helper_does_not_shadow_stream_connection(self):
        connection = self.helper.HTTPConnection('127.0.0.1:55452', timeout=90)
        self.assertEqual(connection.host, '127.0.0.1')
        self.assertEqual(connection.port, 55452)
        connection.close()

    def test_overlap_controller_waits_for_cleanup_before_releasing_stream(self):
        for mode in ('wipe', 'delete'):
            with self.subTest(mode=mode):
                path = 'rides/fixture-user/ride/epoch/attempt.gpx'
                raw = self.work / 'storage' / path / 'version'
                raw.parent.mkdir(parents=True, exist_ok=True)
                events = []

                def sql(statement):
                    if 'begin_account_cleanup' in statement:
                        events.append('begin')
                    if 'finish_account_cleanup' in statement:
                        events.append('finish')
                    return '0' if 'count(*)' in statement else ''

                class Connection:
                    def __init__(self, *args, **kwargs):
                        self.sent = False

                    def putrequest(self, *args): pass
                    def putheader(self, *args): pass
                    def endheaders(self): pass
                    def close(self): pass

                    def send(self, data):
                        if not self.sent:
                            self.sent = True
                            raw.write_bytes(data)
                            events.append('partial')
                        else:
                            assert 'finish' in events
                            events.append('released')
                            raw.unlink()

                    def getresponse(self):
                        class Response:
                            status = 403
                            def read(self): return b'fixture finalization denied'
                        return Response()

                with patch.object(self.helper, 'HTTPConnection', Connection), \
                     patch.object(self.helper, 'new_path', return_value=path), \
                     patch.object(self.helper, 'sql', side_effect=sql), \
                     patch.object(self.helper, 'http', return_value=(200, b'')):
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.helper.overlap({'id': 'fixture-user', 'token': 'fixture-token'}, mode)
                self.assertEqual(events, ['partial', 'begin', 'finish', 'released'])


if __name__ == '__main__':
    unittest.main()
