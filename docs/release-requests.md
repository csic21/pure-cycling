# Explicit Android release requests

Normal source pushes only run CI. To request a release, update
`.github/release-request.json` on `main` with:

- `tag`: a stable semantic version, for example `v0.1.17`.
- `source_sha`: the full lowercase SHA of the tested source commit already on
  `main`. Its `app/pubspec.yaml` version must match the tag (the build number
  remains in the pubspec, for example `0.1.17+18`).

Change this file only when publication is explicitly intended. The initial
request publishes `v0.1.17` from
`b588e2a7b7e89e3025d8a30b5a7c34add27a49ee`. Keeping this workflow does not
instruct an assistant to choose or publish future releases automatically.

`Publish requested release` validates the request and ancestry, runs the
existing Flutter checks and update-service check, then builds from that exact
commit using the existing Android signing and Supabase configuration secrets.
It verifies the APK certificate, saves APK/AAB build artifacts, creates the tag
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
Conflicting tags, unrelated releases, unknown assets, or incomplete asset
uploads stop for review. Do not force tags or clobber assets to bypass a failure.

The original tag-triggered `Release` workflow remains available. Creating a tag
with this workflow's normal `GITHUB_TOKEN` does not start that other workflow;
this workflow therefore performs the complete Android publication itself.
Existing releases, including `v0.1.16`, are not changed. The original workflow's
unsigned iOS artifact is not produced by this Android publication route.
