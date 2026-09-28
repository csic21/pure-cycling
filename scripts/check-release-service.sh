#!/usr/bin/env bash
# Fail a release before building an APK that cannot check its own update feed.
set -euo pipefail

base_url="${1:-}"
repository="${2:-}"
if [[ ! "$base_url" =~ ^https://[^/]+/functions/v1/?$ ]] ||
   [[ ! "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] ||
   [[ "$repository" == */. ]] || [[ "$repository" == */.. ]]; then
  echo 'Invalid release service URL or repository' >&2
  exit 1
fi

headers="$(mktemp)"
body="$(mktemp)"
trap 'rm -f "$headers" "$body"' EXIT

status="$(curl --silent --show-error --max-time 12 \
  --dump-header "$headers" --output "$body" --write-out '%{http_code}' \
  "${base_url%/}/release")"
actual_repository="$(awk 'tolower($1) == "x-release-repository:" { gsub(/\r/, "", $2); print $2 }' "$headers" | tail -1)"
actual_lower="$(printf '%s' "$actual_repository" | tr '[:upper:]' '[:lower:]')"
expected_lower="$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')"
if [[ "$actual_lower" != "$expected_lower" ]]; then
  echo "Release service points to '${actual_repository:-unknown}', expected '$repository'" >&2
  exit 1
fi

case "$status" in
  200)
    jq -e --arg repo "$repository" \
      '(.html_url | ascii_downcase) | startswith("https://github.com/" + ($repo | ascii_downcase) + "/releases/tag/")' \
      "$body" >/dev/null || {
        echo 'Release service returned a release from another repository' >&2
        exit 1
      }
    ;;
  404)
    jq -e '.code == "release_missing"' "$body" >/dev/null || {
      echo 'Release service returned an unexpected 404' >&2
      exit 1
    }
    ;;
  *)
    echo "Release service is unavailable (HTTP $status)" >&2
    exit 1
    ;;
esac

echo "Release service ready for $repository (HTTP $status)"
