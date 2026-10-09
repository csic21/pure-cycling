#!/usr/bin/env bash
#
# Waits until the update relay reports the tag that was just published.
#
# The relay answers from a shared cache, and it is warmed deliberately during
# `verify` — minutes before `publish` creates the Release. So right after a
# release the feed can still be serving the *previous* one, which is exactly
# the version a rider's phone would then be offered, and the APK it would
# download. Waiting here means the release job does not report success while
# the feed the phones consult still points at the version before it.
#
# The default timeout covers the worst case rather than the normal one: until
# `20261009032549_release_cache_fresh_window.sql` is applied, the relay still
# holds a body for ten minutes, and the release is usually published right
# around when that window opens. Once the migration is applied a release
# converges in about a minute, and this exits well before the deadline.
#
# Usage: scripts/wait-for-release-feed.sh <functions-url> <tag>
set -euo pipefail

base_url="${1:-}"
tag="${2:-}"
if [[ ! "$base_url" =~ ^https://[^/]+/functions/v1/?$ ]] || [[ -z "$tag" ]]; then
  echo 'usage: wait-for-release-feed.sh <https://.../functions/v1> <tag>' >&2
  exit 2
fi

timeout_seconds="${FEED_TIMEOUT_SECONDS:-720}"
deadline=$((SECONDS + timeout_seconds))

while true; do
  body="$(curl --silent --show-error --max-time 12 "${base_url%/}/release" || true)"
  reported="$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null || true)"
  if [[ "$reported" == "$tag" ]]; then
    echo "Update feed is serving $tag"
    exit 0
  fi
  if ((SECONDS >= deadline)); then
    echo "::error::Update feed still reports '${reported:-nothing}' after ${timeout_seconds}s, expected $tag" >&2
    exit 1
  fi
  echo "Update feed still reports '${reported:-nothing}'; waiting for $tag"
  sleep 10
done
