# Explicit Android release requests

Normal source pushes only run CI. To request a release, update
`.github/release-request.json` on `main` with:

- `tag`: a stable semantic version, for example `v0.1.17`.
- `source_sha`: the full lowercase SHA of the tested source commit already on
  `main`. Its `app/pubspec.yaml` version must match the tag (the build number
  remains in the pubspec, for example `0.1.17+18`). For a new release, the
  Android build number must be strictly greater than the previous published
  APK’s actual `versionCode`; a higher semantic version alone is insufficient.

Change this file only when publication is explicitly intended. The initial
request publishes `v0.1.17` from
`b588e2a7b7e89e3025d8a30b5a7c34add27a49ee`. Keeping this workflow does not
instruct an assistant to choose or publish future releases automatically.

`Publish requested release` validates the request and ancestry, runs the
existing Flutter checks and update-service check, then builds from that exact
commit using the existing Android signing and Supabase configuration secrets.
It verifies the APK certificate, package and actual Android version, saves
APK/AAB build artifacts, creates the tag
without moving an existing tag, uploads the APK into a draft release, verifies
the uploaded checksum, publishes it, and waits for the app update feed.

Only the publication job has `contents: write`; the other jobs are read-only.
No personal token, new secret, or cross-repository access is needed.

If a transient error occurs, rerun the failed jobs in the same Actions run.
Once a newer stable release exists, older requests stop before publication
rather than making an older version latest again.
A matching tag and a release created by this workflow can be resumed safely;
existing APKs are checked against release provenance and never overwritten.
The original build artifact ID is passed between jobs, including retries.
The previous-release comparison excludes the requested tag. A retry may retain
an already-uploaded APK whose checksum differs from a fresh rebuild, but only
when that existing APK matches its own recorded checksum, the same source/tag
and certificate, and the requested Android package/version. It is never replaced.
Conflicting tags, unrelated releases, unknown assets, or incomplete asset
uploads stop for review. Do not force tags or clobber assets to bypass a failure.

The original tag-triggered `Release` workflow remains available. Creating a tag
with this workflow's normal `GITHUB_TOKEN` does not start that other workflow;
this workflow therefore performs the complete Android publication itself.
Existing releases, including `v0.1.16`, are not changed. The original workflow's
unsigned iOS artifact is not produced by this Android publication route.

## Android upgrade guard

The build and publication jobs use the runner’s installed Android Build Tools:
`aapt2 dump badging` reads the APK’s package, `versionName` and `versionCode`,
and `apksigner verify --verbose --print-certs` verifies its signature. Publication
fails closed if the tools are unavailable or their output cannot be verified.
It does not install tools or infer Android build numbers from semantic tags.

Before creating a tag or draft, publication checks:

1. The checked-out source is the requested commit. Its `app/pubspec.yaml`, the
   requested tag, the actual APK and artifact provenance agree on the version.
2. The APK package is `app.purecycling.cycling`. Every APK signer is the existing
   configured release certificate; signing material and identity are unchanged.
3. The preceding stable published release, excluding this request’s tag, has
   exactly one complete APK. That downloaded APK passes signature verification
   and package/version inspection. The new APK’s `versionCode` is strictly higher.
4. When previous release provenance is present, its source matches its Git tag,
   and its tag, certificate, hash and any recorded Android metadata match the
   downloaded APK. Old provenance containing only source/tag/signer/hash is
   supported by inspecting the actual APK. Releases from the original workflow
   without provenance also require actual APK and signature verification.

New provenance records `package_name`, `version_name` and integer `version_code`
alongside `source_sha`, `tag`, `signer_sha256` and `apk_sha256`. The uploaded APK
is downloaded and verified again before making the draft public. The AAB remains
an Actions artifact; these guards apply to the APK offered by the update feed.

For example, an installed/published `0.1.17+18` requires a later release with an
Android build number above `18`, such as `0.1.18+19`. `0.1.18+18` is rejected.
These are examples, not instructions to bump or publish a release.

Run the deterministic guard and publication-flow tests without an SDK or network:

```sh
python3 -B -m unittest discover -s scripts/tests -p 'test_release_guard.py' -v
```

The release-request validation job runs these tests before building. Validation
helpers are checked out from the triggering workflow commit, separately from
the exact requested app source, so legacy-source retries can use these guards.
The tests cover
actual metadata parsing, source/provenance mismatches, equal/lower/increasing
Android versions, legacy provenance, signer continuity and idempotent retries.
They also execute the workflow’s publication logic against fake GitHub/SDK
responses to check that rejected upgrades perform no release writes.
