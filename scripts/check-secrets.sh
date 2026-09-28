#!/usr/bin/env bash
#
# Scans the working tree for credentials that should never be committed.
#
# Run in CI on every push, and locally before committing. The cost of a false
# positive is a moment's annoyance; the cost of a leaked AMap key is somebody
# else burning your quota until your own users cannot plan a route.
#
#   ./scripts/check-secrets.sh              scan tracked files (or the whole
#                                           tree if this is not a git repository
#                                           yet)
#   ./scripts/check-secrets.sh --all        include gitignored files, to audit
#                                           what is actually sitting on disk
#   ./scripts/check-secrets.sh --self-test  plant decoys and confirm every
#                                           pattern still matches
#
# Written for bash 3.2, which is what macOS still ships: no `mapfile`, no
# associative arrays, no `${var,,}`. This has to work on a developer's laptop
# as well as on a Linux CI runner.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INCLUDE_IGNORED=0
[ "${1:-}" = "--all" ] && INCLUDE_IGNORED=1

problems=0
HITS="$(mktemp)"
trap 'rm -f "$HITS"' EXIT

# ---------------------------------------------------------------------------
# Which files to look at
# ---------------------------------------------------------------------------

# Build output, dependencies, caches. Nothing here is authored by hand, and
# grepping a build directory finds nothing but noise.
prune_args=(
  -not -path './.git/*'
  -not -path '*/build/*'
  -not -path '*/.dart_tool/*'
  -not -path '*/Pods/*'
  -not -path '*/ephemeral/*'
  -not -path '*/.gradle/*'
  -not -path '*/.idea/*'
  -size -2M
)

list_files() {
  if [ "$INCLUDE_IGNORED" -eq 0 ] && git rev-parse --git-dir >/dev/null 2>&1; then
    # Only what git would actually carry into the repository.
    git ls-files -z
  else
    find . -type f "${prune_args[@]}" -print0
  fi
}

# ---------------------------------------------------------------------------
# Scanning
#
# Every pattern is plain ERE: BSD grep on macOS has no `-P`. The one
# case-insensitive pattern carries a `(?i)` marker which is stripped here and
# turned into `-i`, since there is no inline flag either.
# ---------------------------------------------------------------------------

scan() {
  local pattern="$1" severity="$2" what="$3" detail="$4"
  local flags="-nE"

  case "$pattern" in
    '(?i)'*)
      flags="-nEi"
      pattern="${pattern#'(?i)'}"
      ;;
  esac

  while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue

    # grep writes to a file rather than into a pipe. Piping would run the
    # reader in a subshell, and `problems` incremented there would be thrown
    # away — the classic way a scanner ends up always reporting "clean".
    grep -I "$flags" -- "$pattern" "$file" >"$HITS" 2>/dev/null

    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      problems=$((problems + 1))
      printf '\n  [%s] %s\n' "$severity" "$what"
      printf '         %s:%s\n' "${file#./}" "${hit%%:*}"
      printf '         %s\n' "$detail"
    done <"$HITS"
  done < <(list_files)
}

# ---------------------------------------------------------------------------

# A Supabase JWT. The role lives in the payload, which is all that is needed
# to tell a harmless publishable key from a catastrophic one.
SUPABASE_JWT='eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'

# Supabase's newer elevated API key is no longer a JWT.
SUPABASE_SECRET='sb_secret_[A-Za-z0-9_-]{16,}'

# An AMap Web Service key is 32 hex characters, but only when the line also
# names it. A bare 32-hex string is equally likely to be a commit hash or a
# colour value, and a scanner that cries wolf gets switched off.
#
# The trailing boundary matters: without it, a 40-character commit hash
# contains a 32-hex substring and every such line becomes a finding.
AMAP_KEY='(?i)(amap|gaode|高德).*[0-9a-f]{32}([^0-9a-f]|$)'

SUPABASE_URL='https://[a-z0-9]{16,}\.supabase\.(co|in)'

# A service_role key pasted next to its own name. Deliberately narrow: matching
# the bare words "service_role" fires on every comment in the repository,
# including the one you are reading, and a scanner that cries wolf gets
# switched off. The JWT check above catches everything this one misses.
#
# `.*` rather than a character class between the two, because the text in
# between is usually `_KEY=` — and `KEY` is alphanumeric, so a negated class
# stops dead at the K.
SERVICE_ROLE_KEY='(?i)service[_ -]?role.*eyJ[A-Za-z0-9_-]{10,}'

if [ "${1:-}" = "--self-test" ]; then
  # A scanner whose patterns have quietly stopped matching is worse than no
  # scanner: the build goes green and everyone stops thinking about it. So
  # every pattern gets tested against a decoy on each run.
  #
  # The decoys are assembled from fragments on purpose. Written out whole, they
  # would sit in this file as literal credentials and the scanner would find
  # them — reporting its own test fixtures as leaks, forever.
  DECOYS="$(mktemp -d)"
  trap 'rm -f "$HITS"; rm -rf "$DECOYS"' EXIT

  _hex_a="aaaa1111bbbb2222"
  _hex_b="cccc3333dddd4444"
  _jwt_head="eyJhbGciOiJIUzI1NiJ9"
  _jwt_payload="eyJyb2xlIjoiYW5vbiIsInR5cCI6IkpXVCJ9"
  _jwt_sig="abcdefghijklmnopqrstuvwxyz"
  _host="abcdefghijklmnop"

  printf 'const k = "amap_key: %s%s";\n' "$_hex_a" "$_hex_b" >"$DECOYS/amap.dart"
  printf 'k = "%s.%s.%s"\n' "$_jwt_head" "$_jwt_payload" "$_jwt_sig" >"$DECOYS/jwt.dart"
  printf 'SUPABASE_SERVICE_ROLE_KEY=%s.%s.%s\n' \
    "$_jwt_head" "$_jwt_payload" "$_jwt_sig" >"$DECOYS/role.env"
  printf 'SUPABASE_SECRET_KEY=%s%s\n' 'sb_secret_' \
    'abcdefghijklmnopqrstuvwxyz' >"$DECOYS/secret.env"
  printf 'url = "https://%s.supabase.co"\n' "$_host" >"$DECOYS/url.dart"

  echo "==> self-test"
  failures=0

  check_pattern() {
    local label="$1" pattern="$2" decoy="$3" flags="-nE"
    case "$pattern" in
      '(?i)'*) flags="-nEi"; pattern="${pattern#'(?i)'}" ;;
    esac
    if grep -q $flags -- "$pattern" "$DECOYS/$decoy" 2>/dev/null; then
      printf '    ok    %s\n' "$label"
    else
      printf '    FAIL  %s — the pattern no longer matches its decoy\n' "$label"
      failures=$((failures + 1))
    fi
  }

  check_pattern "AMap Web Service key" "$AMAP_KEY" "amap.dart"
  check_pattern "Supabase JWT" "$SUPABASE_JWT" "jwt.dart"
  check_pattern "service_role key" "$SERVICE_ROLE_KEY" "role.env"
  check_pattern "Supabase secret key" "$SUPABASE_SECRET" "secret.env"
  check_pattern "Supabase project URL" "$SUPABASE_URL" "url.dart"

  # And a negative case: a line that mentions AMap but carries no key must not
  # be reported, or the scanner trains its readers to ignore it.
  printf '// amap, but no key on this line\n' >"$DECOYS/decoy_negative.dart"
  if grep -qEi -- "${AMAP_KEY#'(?i)'}" "$DECOYS/decoy_negative.dart" 2>/dev/null; then
    printf '    FAIL  false positive on a keyless mention of amap\n'
    failures=$((failures + 1))
  else
    printf '    ok    no false positive on a keyless mention\n'
  fi

  if [ "$failures" -eq 0 ]; then
    echo "==> self-test passed"
    exit 0
  fi
  echo "==> self-test FAILED"
  exit 1
fi

echo "==> scanning for credentials"

scan "$SUPABASE_JWT" \
  "CRITICAL" \
  "Supabase JWT" \
  "Decode the payload to see the role: echo '<token>' | cut -d. -f2 | base64 -d. \
A publishable key is expected here. A service_role key bypasses every RLS \
policy — rotate it and clean history."

scan "$AMAP_KEY" \
  "HIGH" \
  "possible AMap Web Service key" \
  "AMap keys are billed by quota and scraped from public repositories within \
hours. A leaked key breaks route planning for real users."

scan "$SERVICE_ROLE_KEY" \
  "CRITICAL" \
  "service_role key" \
  "This bypasses every RLS policy: whoever holds it can read and delete every \
user's data. Never in a client build. Rotate it and clean history."

scan "$SUPABASE_SECRET" \
  "CRITICAL" \
  "Supabase secret key" \
  "This bypasses every RLS policy. Rotate it and remove it from the repository."

scan "$SUPABASE_URL" \
  "INFO" \
  "Supabase project URL" \
  "Not a secret on its own — it ships inside every app binary. Only a problem \
alongside a hard-coded service_role key."

if [ "$problems" -eq 0 ]; then
  echo "==> clean"
  exit 0
fi

printf '\n==> %d finding(s)\n' "$problems"

cat <<'EOF'

  Not every hit is a leak — a fixture, a doc example or a placeholder will all
  match. Read each one.

  If a real credential has been committed:
    1. Rotate it FIRST. Assume it is compromised the moment it is pushed;
       deleting the file in a later commit does not un-push it.
    2. Only then clean history (git filter-repo / BFG) and force-push.

  For local development, put real values in app/dart_define.json — which is
  gitignored — and run:
      flutter run --dart-define-from-file=dart_define.json
EOF

exit 1
