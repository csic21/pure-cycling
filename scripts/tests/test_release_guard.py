"""Deterministic unit and publication-flow tests; no network, keys or SDK needed."""

from dataclasses import asdict, replace
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from scripts import release_guard as guard

ROOT = Path(__file__).resolve().parents[2]
SOURCE = 'a' * 40
OLDER_SOURCE = 'b' * 40
SIGNER = 'c' * 64
DIGEST = 'd' * 64
CANDIDATE = guard.ApkMetadata(guard.PACKAGE_NAME, '0.1.18', 19)
OLDER = guard.ApkMetadata(guard.PACKAGE_NAME, '0.1.17', 18)


def provenance(metadata=CANDIDATE, source=SOURCE, digest=DIGEST):
    return dict(source_sha=source, tag='v' + metadata.version_name,
                signer_sha256=SIGNER, apk_sha256=digest, **asdict(metadata))


def release(tag, **kwargs):
    return dict(tag_name=tag, draft=False, prerelease=False, **kwargs)


class MetadataTests(unittest.TestCase):
    def test_badging_reads_actual_version_fields(self):
        self.assertEqual(guard.parse_badging(
            "package: name='app.purecycling.cycling' versionCode='19' "
            "versionName='0.1.18' platformBuildVersionName='16'\n"
            "sdkVersion:'23'\n"), CANDIDATE)

    def test_badging_fails_closed_on_incomplete_or_ambiguous_metadata(self):
        good = "package: name='app.purecycling.cycling' versionCode='19' versionName='0.1.18'"
        for report in ('', good + '\n' + good, good.replace("versionCode='19'", ''),
                       good.replace("versionCode='19'", "versionCode='no'"),
                       good + " versionCode='20'", good + " versionCodeMajor='1'",
                       good.replace("versionCode='19'", "versionCode='0'"),
                       good.replace("versionCode='19'", "versionCode='2100000001'")):
            with self.subTest(report=report), self.assertRaises(guard.ReleaseGuardError):
                guard.parse_badging(report)

    def test_source_version_includes_build_number(self):
        self.assertEqual(guard.source_version('name: app\nversion: 0.1.18+19\n', 'v0.1.18'), CANDIDATE)

    def test_invalid_source_versions_fail(self):
        for pubspec, tag in [('version: 0.1.18', 'v0.1.18'),
                             ('version: 0.1.18+0', 'v0.1.18'),
                             ('version: 0.1.18+2100000001', 'v0.1.18'),
                             ('version: 0.1.18+19', 'v0.1.19'),
                             ('version: 0.1.18+19', 'v0.1.18-beta'),
                             ('version: 0.1.18+19\nversion: 0.1.18+19', 'v0.1.18')]:
            with self.subTest(pubspec=pubspec, tag=tag), self.assertRaises(guard.ReleaseGuardError):
                guard.source_version(pubspec, tag)

    def test_inspection_uses_android_tool_on_actual_file(self):
        report = "package: name='app.purecycling.cycling' versionCode='19' versionName='0.1.18'"
        with patch.object(guard, 'android_tool', return_value='/sdk/aapt2'), \
             patch.object(subprocess, 'check_output', return_value=report) as run:
            self.assertEqual(guard.inspect_apk(Path('/tmp/candidate.apk')), CANDIDATE)
            run.assert_called_once_with(['/sdk/aapt2', 'dump', 'badging', '/tmp/candidate.apk'], text=True)

    def test_android_tool_selects_highest_installed_stable_version(self):
        with tempfile.TemporaryDirectory() as directory:
            for version in ('9.0.0', '35.0.0', '36.0.0', '37.0.0-rc1'):
                tool = Path(directory) / 'build-tools' / version / 'aapt2'
                tool.parent.mkdir(parents=True)
                tool.touch()
            with patch.dict(os.environ, {'ANDROID_HOME': directory, 'ANDROID_SDK_ROOT': ''}), \
                 patch.object(guard.shutil, 'which', return_value=None):
                self.assertEqual(guard.android_tool('aapt2'), str(Path(directory) / 'build-tools/36.0.0/aapt2'))

    def test_missing_android_tools_fail_instead_of_guessing(self):
        with patch.dict(os.environ, {'ANDROID_HOME': '', 'ANDROID_SDK_ROOT': ''}), \
             patch.object(guard.shutil, 'which', return_value=None), \
             self.assertRaisesRegex(guard.ReleaseGuardError, 'unavailable'):
            guard.android_tool('aapt2')


class ProvenanceTests(unittest.TestCase):
    def validate(self, manifest=None, metadata=CANDIDATE, pubspec='version: 0.1.18+19'):
        guard.validate_candidate(provenance() if manifest is None else manifest,
                                 metadata, DIGEST, source=SOURCE, tag='v0.1.18',
                                 signer=SIGNER, pubspec=pubspec)

    def test_consistent_candidate_passes(self):
        self.validate()

    def test_provenance_mismatches_fail(self):
        for key, value in [('package_name', 'other.app'), ('version_name', '0.1.17'),
                           ('version_code', 18), ('version_code', '19'), ('version_code', True),
                           ('source_sha', 'b' * 40), ('tag', 'v0.1.19'),
                           ('signer_sha256', '0' * 64), ('apk_sha256', '0' * 64)]:
            with self.subTest(key=key, value=value), self.assertRaises(guard.ReleaseGuardError):
                self.validate(dict(provenance(), **{key: value}))

    def test_wrong_actual_package_fails_even_if_provenance_agrees(self):
        metadata = replace(CANDIDATE, package_name='other.app')
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'package'):
            self.validate(provenance(metadata), metadata)

    def test_actual_build_number_must_match_source(self):
        metadata = replace(CANDIDATE, version_code=20)
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'source pubspec'):
            self.validate(provenance(metadata), metadata)

    def test_actual_version_name_must_match_tag(self):
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'versionName'):
            self.validate(metadata=replace(CANDIDATE, version_name='0.1.19'))

    def test_new_candidate_requires_all_android_metadata(self):
        manifest = provenance()
        for key in guard.METADATA_FIELDS:
            del manifest[key]
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'missing Android'):
            self.validate(manifest)

    def test_old_provenance_without_version_fields_uses_actual_apk(self):
        manifest = provenance(OLDER, OLDER_SOURCE)
        for key in guard.METADATA_FIELDS:
            del manifest[key]
        guard.validate_provenance(manifest, OLDER, DIGEST, source=OLDER_SOURCE,
                                  tag='v0.1.17', signer=SIGNER, allow_legacy=True)
        # The old format still binds the APK hash, signer, source and tag.
        for key in ('apk_sha256', 'signer_sha256', 'source_sha', 'tag'):
            with self.subTest(key=key), self.assertRaises(guard.ReleaseGuardError):
                guard.validate_provenance(dict(manifest, **{key: 'wrong'}), OLDER, DIGEST,
                                          source=OLDER_SOURCE, tag='v0.1.17', signer=SIGNER,
                                          allow_legacy=True)

    def test_partial_legacy_metadata_is_not_silently_ignored(self):
        manifest = provenance(OLDER, OLDER_SOURCE)
        del manifest['version_code']
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'missing Android'):
            guard.validate_provenance(manifest, OLDER, DIGEST, source=OLDER_SOURCE,
                                      tag='v0.1.17', signer=SIGNER, allow_legacy=True)

    def test_release_notes_allow_legacy_absence_but_reject_malformed_marker(self):
        self.assertIsNone(guard.release_provenance('Original release notes'))
        note = '<!-- pure-cycling-release: ' + json.dumps(provenance()) + ' -->'
        self.assertEqual(guard.release_provenance(note), provenance())
        for body in (note + note, '<!-- pure-cycling-release: {bad} -->',
                     '<!-- pure-cycling-release: missing -->'):
            with self.subTest(body=body), self.assertRaises(guard.ReleaseGuardError):
                guard.release_provenance(body)


class SignerTests(unittest.TestCase):
    def test_supported_signer_formats_retain_same_certificate(self):
        names = ('Signer #1', 'Signer (minSdkVersion=24, maxSdkVersion=32)',
                 'V1 Signer #1:', 'V2 Signer:', 'V3.0 Signer:',
                 'V3.1 Signer: (minSdkVersion=33, maxSdkVersion=2147483647)',
                 'V3.2 Hybrid Classical Signer:')
        report = '\n'.join(name + ' certificate SHA-256 digest: ' + SIGNER.upper() for name in names)
        guard.verify_signer_report(report, SIGNER)

    def test_unknown_signer_or_different_certificate_fails(self):
        good = 'Signer #1 certificate SHA-256 digest: ' + SIGNER
        for report in ('', good + '\nSigner #2 certificate SHA-256 digest: ' + 'd' * 64,
                       good + '\nFuture Signer certificate SHA-256 digest: ' + SIGNER):
            with self.subTest(report=report), self.assertRaises(guard.ReleaseGuardError):
                guard.verify_signer_report(report, SIGNER)


class UpgradeAndRetryTests(unittest.TestCase):
    def test_increasing_code_passes(self):
        guard.validate_upgrade(CANDIDATE, OLDER, previous_tag='v0.1.17')

    def test_equal_and_lower_codes_fail_despite_higher_semantic_version(self):
        for code in (18, 17):
            with self.subTest(code=code), self.assertRaisesRegex(guard.ReleaseGuardError, 'must increase'):
                guard.validate_upgrade(replace(CANDIDATE, version_code=code), OLDER, previous_tag='v0.1.17')

    def test_previous_apk_package_and_tag_must_match(self):
        for previous in (replace(OLDER, package_name='other.app'), replace(OLDER, version_name='0.1.16')):
            with self.subTest(previous=previous), self.assertRaises(guard.ReleaseGuardError):
                guard.validate_upgrade(CANDIDATE, previous, previous_tag='v0.1.17')

    def test_previous_release_excludes_same_tag_retry_and_non_stable_releases(self):
        older = release('v0.1.17')
        releases = [release('v0.1.18'), older, release('v0.1.16'),
                    dict(release('v0.1.19'), draft=True),
                    dict(release('v0.1.20'), prerelease=True), release('v0.1.19-rc1')]
        self.assertIs(guard.previous_release(releases, 'v0.1.18'), older)
        self.assertIsNone(guard.previous_release([release('v0.1.18')], 'v0.1.18'))

    def test_newer_stable_release_blocks_old_retry(self):
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'newer stable'):
            guard.previous_release([release('v0.1.19'), release('v0.1.18')], 'v0.1.18')

    def test_rebuilt_retry_retains_original_apk_hash(self):
        old_digest = 'e' * 64
        existing = provenance(digest=old_digest)
        guard.validate_retry(provenance(), existing, CANDIDATE, old_digest)
        for key in guard.METADATA_FIELDS:
            del existing[key]
        guard.validate_retry(provenance(), existing, CANDIDATE, old_digest)

    def test_retry_must_match_source_signer_hash_and_actual_versions(self):
        for key, value in [('source_sha', OLDER_SOURCE), ('signer_sha256', 'e' * 64),
                           ('apk_sha256', 'e' * 64), ('version_code', 20), ('tag', 'v0.1.17')]:
            with self.subTest(key=key), self.assertRaises(guard.ReleaseGuardError):
                guard.validate_retry(provenance(), dict(provenance(), **{key: value}), CANDIDATE, DIGEST)
        with self.assertRaises(guard.ReleaseGuardError):
            guard.validate_retry(provenance(), provenance(replace(CANDIDATE, version_code=20)),
                                 replace(CANDIDATE, version_code=20), DIGEST)


class PublicationFlowTests(unittest.TestCase):
    """Execute the workflow's real Python using an in-memory GitHub/SDK double.

    Assert failed guards issue no writes and an intact retry never replaces an
    existing asset. This tests guard placement, not just the helper functions.
    """

    @classmethod
    def setUpClass(cls):
        workflow = (ROOT / '.github/workflows/publish-request.yml').read_text()
        publish = workflow.split('  publish:\n', 1)[1]
        block = publish.split("          python3 - <<'PY'\n", 1)[1].split('\n          PY', 1)[0]
        cls.program = compile('\n'.join(line[10:] for line in block.splitlines()), '<publish-workflow>', 'exec')

    def exercise(self, *, code=19, retry=False, legacy=False, baseline_metadata=OLDER,
                 candidate_package=guard.PACKAGE_NAME, existing_source=SOURCE,
                 baseline_provenance_change=None, missing_baseline=False, no_provenance=False):
        candidate = replace(CANDIDATE, version_code=code, package_name=candidate_package)
        payloads = {1: b'baseline', 2: b'existing', 3: b'candidate'}
        metadata = {b'baseline': baseline_metadata, b'existing': candidate, b'candidate': candidate}
        digest = lambda payload: hashlib.sha256(payload).hexdigest()
        candidate_manifest = provenance(candidate, digest=digest(b'candidate'))
        older_manifest = provenance(baseline_metadata, OLDER_SOURCE, digest(b'baseline'))
        # Public release tag is independent of the metadata read from its APK.
        older_manifest['tag'] = 'v0.1.17'
        if legacy:
            for key in guard.METADATA_FIELDS:
                del older_manifest[key]
        if baseline_provenance_change:
            older_manifest.update(baseline_provenance_change)
        body = lambda value: '<!-- pure-cycling-release: ' + json.dumps(value) + ' -->'
        baseline = release('v0.1.17', id=10, target_commitish=OLDER_SOURCE,
                           body='Original release notes' if no_provenance else body(older_manifest),
                           assets=[] if missing_baseline else [
                               dict(id=1, name='pure-cycling-android.apk', state='uploaded')])
        releases = [baseline]
        tags = {'v0.1.17': OLDER_SOURCE}
        if retry:
            existing_manifest = provenance(candidate, existing_source, digest(b'existing'))
            if legacy:
                for key in guard.METADATA_FIELDS:
                    del existing_manifest[key]
            releases.append(release('v0.1.18', id=20, target_commitish=SOURCE,
                                    body=body(existing_manifest), assets=[
                                        dict(id=2, name='pure-cycling-android.apk', state='uploaded')]))
            tags['v0.1.18'] = SOURCE
        mutations = []
        self.mutations = mutations

        def run(command, **kwargs):
            if command[:3] == ['gh', 'release', 'upload']:
                mutations.append(('upload', command))
                releases[-1]['assets'] = [dict(id=3, name='pure-cycling-android.apk', state='uploaded')]
                return SimpleNamespace(stdout='')
            self.assertEqual(command[:2], ['gh', 'api'])
            endpoint = command[2].removeprefix('repos/csic21/pure-cycling').lstrip('/')
            if 'stdout' in kwargs:
                kwargs['stdout'].write(payloads[int(endpoint.rsplit('/', 1)[1])])
                return SimpleNamespace(stdout=None)
            method = command[command.index('--method') + 1]
            data = json.loads(kwargs['input']) if kwargs.get('input') else None
            if method != 'GET':
                mutations.append((method, endpoint))
            if endpoint == '':
                result = dict(visibility='public')
            elif endpoint.startswith('releases?'):
                result = releases
            elif endpoint.startswith('git/matching-refs/tags/'):
                tag = endpoint.rsplit('/', 1)[1]
                result = [dict(ref='refs/tags/' + tag, object=dict(type='commit', sha=tags[tag]))] if tag in tags else []
            elif endpoint == 'git/refs':
                tags[data['ref'].removeprefix('refs/tags/')] = data['sha']
                result = {}
            elif endpoint == 'releases' and method == 'POST':
                result = dict(data, id=20, assets=[])
                releases.append(result)
            elif endpoint == 'releases/20':
                result = releases[-1]
                if method == 'PATCH':
                    result.update(data)
            else:
                self.fail(f'Unexpected fake GitHub call: {command}')
            return SimpleNamespace(stdout=json.dumps(result))

        with tempfile.TemporaryDirectory() as directory:
            original = os.getcwd()
            try:
                os.chdir(directory)
                Path('release-artifacts').mkdir()
                Path('release-artifacts/pure-cycling-android.apk').write_bytes(b'candidate')
                Path('release-artifacts/release-manifest.json').write_text(json.dumps(candidate_manifest))
                Path('app').mkdir()
                Path('app/pubspec.yaml').write_text(f'version: 0.1.18+{code}\n')
                with patch.dict(os.environ, dict(RELEASE_REPOSITORY='csic21/pure-cycling',
                                                RELEASE_TAG='v0.1.18', RELEASE_SOURCE_SHA=SOURCE)), \
                     patch.object(subprocess, 'run', side_effect=run), \
                     patch.object(subprocess, 'check_output', return_value=SOURCE), \
                     patch.object(guard, 'inspect_apk', side_effect=lambda path: metadata[Path(path).read_bytes()]), \
                     patch.object(guard, 'verify_apk_signer') as signature_check:
                    exec(self.program, {'__name__': '__main__'})
                    self.assertGreaterEqual(signature_check.call_count, 3)
            finally:
                os.chdir(original)
        return mutations

    def test_increasing_code_can_publish_after_read_only_validation(self):
        self.assertEqual([method for method, _ in self.exercise()], ['POST', 'POST', 'upload', 'PATCH'])

    def test_equal_and_lower_codes_are_blocked_before_any_write(self):
        for code in (18, 17):
            with self.subTest(code=code), self.assertRaisesRegex(guard.ReleaseGuardError, 'must increase'):
                self.exercise(code=code)
            self.assertEqual(self.mutations, [])

    def test_package_mismatch_is_blocked_before_any_write(self):
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'package'):
            self.exercise(candidate_package='other.app')
        self.assertEqual(self.mutations, [])

    def test_previous_provenance_mismatch_is_blocked_before_any_write(self):
        for change in ({'version_code': 17}, {'source_sha': SOURCE}, {'apk_sha256': 'f' * 64}):
            with self.subTest(change=change), self.assertRaises(guard.ReleaseGuardError):
                self.exercise(baseline_provenance_change=change)
            self.assertEqual(self.mutations, [])

    def test_previous_actual_code_is_used_with_legacy_provenance(self):
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'must increase'):
            self.exercise(legacy=True, baseline_metadata=replace(OLDER, version_code=23))
        self.assertEqual(self.mutations, [])

    def test_original_workflow_without_provenance_still_inspects_actual_apk(self):
        self.assertEqual([method for method, _ in self.exercise(no_provenance=True)],
                         ['POST', 'POST', 'upload', 'PATCH'])
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'must increase'):
            self.exercise(no_provenance=True, baseline_metadata=replace(OLDER, version_code=23))
        self.assertEqual(self.mutations, [])

    def test_missing_previous_apk_blocks_publication(self):
        with self.assertRaisesRegex(SystemExit, 'exactly one Android APK'):
            self.exercise(missing_baseline=True)
        self.assertEqual(self.mutations, [])

    def test_published_retry_is_read_only_and_uses_original_apk(self):
        self.assertEqual(self.exercise(retry=True), [])
        self.assertEqual(self.exercise(retry=True, legacy=True), [])

    def test_retry_does_not_bypass_older_version_code_guard(self):
        with self.assertRaisesRegex(guard.ReleaseGuardError, 'must increase'):
            self.exercise(code=18, retry=True)
        self.assertEqual(self.mutations, [])

    def test_retry_with_different_provenance_source_is_untouched(self):
        with self.assertRaisesRegex(SystemExit, 'different source'):
            self.exercise(retry=True, existing_source=OLDER_SOURCE)
        self.assertEqual(self.mutations, [])


if __name__ == '__main__':
    unittest.main()
