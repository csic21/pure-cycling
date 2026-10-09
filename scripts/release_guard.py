#!/usr/bin/env python3
"""Read-only Android release checks shared by build and publication jobs.

Only Android Build Tools inspect APKs. A tag, a pubspec or provenance alone is
never evidence of the versionCode actually installed by Android.
"""

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

PACKAGE_NAME = 'app.purecycling.cycling'
MAX_VERSION_CODE = 2100000000
TAG_PATTERN = r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
METADATA_FIELDS = {'package_name', 'version_name', 'version_code'}
PROVENANCE_MARKER = 'pure-cycling-release'


class ReleaseGuardError(ValueError):
    """Fail closed when release identity or upgrade compatibility is uncertain."""


def require(condition, message):
    if not condition:
        raise ReleaseGuardError(message)


@dataclass(frozen=True)
class ApkMetadata:
    package_name: str
    version_name: str
    version_code: int


def stable_version(tag):
    match = re.fullmatch(TAG_PATTERN, tag) if isinstance(tag, str) else None
    require(match is not None, 'Release tag must be a stable semantic version.')
    return tuple(map(int, match.groups()))


def source_version(pubspec, tag):
    stable_version(tag)
    matches = re.findall(r'^version:[ \t]*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)[ \t]*$', pubspec, re.M)
    require(len(matches) == 1, 'Source pubspec must contain one versionName+versionCode.')
    name, code = matches[0]
    require(tag == 'v' + name, 'Release tag does not match the source pubspec version.')
    require(0 < int(code) <= MAX_VERSION_CODE, 'Source versionCode is outside the Android range.')
    return ApkMetadata(PACKAGE_NAME, name, int(code))


def parse_badging(report):
    lines = [line for line in report.splitlines() if line.startswith('package:')]
    require(len(lines) == 1, 'Android tooling did not report exactly one APK package.')
    pairs = re.findall(r"([A-Za-z][A-Za-z0-9]*)='([^']*)'", lines[0])
    fields = dict(pairs)
    require(len(fields) == len(pairs), 'Android tooling reported duplicate APK fields.')
    require(all(key in fields for key in ('name', 'versionName', 'versionCode')),
            'Android tooling did not report package, versionName and versionCode.')
    code = fields['versionCode']
    require(re.fullmatch(r'[0-9]+', code) is not None, 'APK versionCode is not an integer.')
    require(0 < int(code) <= MAX_VERSION_CODE, 'APK versionCode is outside the Android range.')
    require(fields.get('versionCodeMajor', '0') == '0', 'Unexpected APK versionCodeMajor.')
    return ApkMetadata(fields['name'], fields['versionName'], int(code))


def android_tool(name):
    """Use already installed SDK tools; never install or download a tool here."""
    candidates = set()
    for variable in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        root = os.environ.get(variable)
        if root:
            candidates.update(Path(root).glob(f'build-tools/*/{name}'))
    # Prefer stable numeric Build Tools releases over previews.
    candidates = [path for path in candidates if path.is_file()
                  and re.fullmatch(r'\d+(?:\.\d+)*', path.parent.name)]
    if candidates:
        return str(max(candidates, key=lambda path: tuple(map(int, path.parent.name.split('.')))))
    found = shutil.which(name)
    require(found is not None, f'Android Build Tools {name} is unavailable; refusing publication.')
    return found


def inspect_apk(apk):
    report = subprocess.check_output([android_tool('aapt2'), 'dump', 'badging', str(apk)], text=True)
    return parse_badging(report)


def verify_signer_report(report, expected_signer):
    require(isinstance(expected_signer, str) and re.fullmatch(r'[0-9a-f]{64}', expected_signer),
            'Artifact has no verified signing certificate.')
    sdk_range = r'\(minSdkVersion=\d+(?: \(dev release=true\))?, maxSdkVersion=\d+\)'
    signer_name = (rf'(?:Signer #\d+|Signer {sdk_range}|'
                   rf'(?:V[12]|V3\.[012](?: Hybrid (?:Classical|PQC))?) '
                   rf'Signer(?: #\d+)?:(?: {sdk_range})?)')
    signers = re.findall(rf'^({signer_name}) certificate SHA-256 digest: '
                         r'([0-9a-fA-F]{64})[ \t]*$', report, re.M)
    certificate_lines = [line for line in report.splitlines()
                         if ' certificate SHA-256 digest:' in line
                         and not line.startswith('Source Stamp Signer')]
    require(signers and len(signers) == len(certificate_lines),
            'Could not parse every APK signer certificate; refusing publication.')
    require({value.lower() for _, value in signers} == {expected_signer},
            'APK signer certificates differ from the configured release certificate.')


def verify_apk_signer(apk, expected_signer):
    report = subprocess.check_output([android_tool('apksigner'), 'verify', '--verbose',
                                      '--print-certs', str(apk)], text=True)
    verify_signer_report(report, expected_signer)


def apk_sha256(apk):
    digest = hashlib.sha256()
    with Path(apk).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def release_provenance(body):
    matches = re.findall(r'<!-- ' + PROVENANCE_MARKER + r': (\{[^\n]+\}) -->', body or '')
    if not matches:
        require(PROVENANCE_MARKER not in (body or ''), 'Malformed release provenance marker.')
        return None  # The original tag workflow did not emit provenance.
    require(len(matches) == 1, 'Ambiguous release provenance.')
    try:
        result = json.loads(matches[0])
    except (ValueError, TypeError) as error:
        raise ReleaseGuardError('Malformed release provenance JSON.') from error
    require(isinstance(result, dict), 'Release provenance must be an object.')
    return result


def validate_provenance(manifest, metadata, digest, *, source, tag, signer, allow_legacy=False):
    require(isinstance(manifest, dict), 'Artifact provenance must be an object.')
    require(isinstance(source, str) and re.fullmatch(r'[0-9a-f]{40}', source), 'Invalid release source SHA.')
    stable_version(tag)
    require((manifest.get('source_sha'), manifest.get('tag')) == (source, tag),
            'Artifact provenance does not match the approved source and tag.')
    require(isinstance(signer, str) and re.fullmatch(r'[0-9a-f]{64}', signer)
            and manifest.get('signer_sha256') == signer,
            'Artifact signing provenance differs from the configured release certificate.')
    require(manifest.get('apk_sha256') == digest, 'APK differs from its recorded signed build.')
    require(metadata.package_name == PACKAGE_NAME, 'APK package does not match the release application.')
    require('v' + metadata.version_name == tag, 'APK versionName does not match the release tag.')
    present = METADATA_FIELDS.intersection(manifest)
    require(present == METADATA_FIELDS or (allow_legacy and not present),
            'Artifact provenance is missing Android package/version metadata.')
    if present:
        require(type(manifest['version_code']) is int, 'Provenance versionCode must be an integer.')
        require(all(manifest[key] == value for key, value in asdict(metadata).items()),
                'APK package/version metadata does not match provenance.')


def validate_candidate(manifest, metadata, digest, *, source, tag, signer, pubspec):
    validate_provenance(manifest, metadata, digest, source=source, tag=tag, signer=signer)
    require(metadata == source_version(pubspec, tag),
            'Built APK package/version does not match the requested source pubspec.')


def create_manifest(apk, *, source, tag, signer, pubspec):
    metadata = inspect_apk(apk)
    manifest = dict(source_sha=source, tag=tag, signer_sha256=signer,
                    apk_sha256=apk_sha256(apk), **asdict(metadata))
    validate_candidate(manifest, metadata, manifest['apk_sha256'], source=source,
                       tag=tag, signer=signer, pubspec=pubspec)
    return manifest


def previous_release(releases, tag):
    """Find the preceding stable release, excluding this tag for retries."""
    requested = stable_version(tag)
    older = []
    seen = set()
    for release in releases:
        if release['draft'] or release['prerelease'] or not re.fullmatch(TAG_PATTERN, release['tag_name']):
            continue
        version = stable_version(release['tag_name'])
        require(version <= requested, 'A newer stable release exists; refusing to promote an older request.')
        if release['tag_name'] == tag:
            continue
        require(release['tag_name'] not in seen, 'Multiple published releases have the same tag.')
        seen.add(release['tag_name'])
        older.append(release)
    return max(older, key=lambda release: stable_version(release['tag_name'])) if older else None


def validate_upgrade(candidate, previous, *, previous_tag):
    stable_version(previous_tag)
    require(previous.package_name == candidate.package_name == PACKAGE_NAME,
            'Previous APK package does not match the release application.')
    require('v' + previous.version_name == previous_tag,
            'Previous APK versionName does not match its published tag.')
    require(candidate.version_code > previous.version_code,
            f'Android versionCode must increase: candidate {candidate.version_code}, '
            f'previous published {previous.version_code} ({previous_tag}).')


def validate_retry(manifest, existing, metadata, digest):
    """Accept an intact existing build of the same source, not a rebuilt hash.

    APK builds need not be bit-for-bit reproducible. An existing APK is retained
    only when its own original provenance/hash and actual version match.
    """
    validate_provenance(existing, metadata, digest, source=manifest['source_sha'],
                        tag=manifest['tag'], signer=manifest['signer_sha256'], allow_legacy=True)
    require(asdict(metadata) == {key: manifest[key] for key in METADATA_FIELDS},
            'Existing APK does not match the requested Android package/version.')
