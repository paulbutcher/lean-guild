# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Helpers for Forgejo's API, sourced by kit. The project's configuration is what its kit
# executable exported, mounted at /etc/kit.

FORGE_URL="${FORGE_URL:-http://forgejo:3000}"
ORG="${FORGE_ORG:?}"
# shellcheck disable=SC1091
. /etc/kit/project.env
RESP="$(mktemp)"
REQ="$(mktemp)"
CHANGES=0

log() { printf '%s\n' "$*" >&2; }
die() { log "kit: $*"; exit 1; }
changed() { CHANGES=$((CHANGES + 1)); log "  $*"; }

token_of() {
  [ -s "/secrets/$1/token" ] || die "no token in secrets/$1/token"
  tr -d '[:space:]' < "/secrets/$1/token"
}

# api METHOD PATH [JSON]: prints the HTTP status; the body is in $RESP. Authenticates with
# $TOKEN, or with $BASIC (user:password) when that is set.
api() {
  local method="$1" path="$2" body="${3:-}" auth
  if [ -n "${BASIC:-}" ]; then auth=(-u "$BASIC"); else auth=(-H "Authorization: token ${TOKEN:?}"); fi
  local args=(-sS -X "$method" "${auth[@]}" -H 'Accept: application/json' -o "$RESP" -w '%{http_code}')
  # From a file: an argument is limited to 128 KiB.
  [ -n "$body" ] && { printf '%s' "$body" > "$REQ"; args+=(-H 'Content-Type: application/json' --data-binary "@$REQ"); }
  curl "${args[@]}" "$FORGE_URL/api/v1$path"
}

# call EXPECTED METHOD PATH [JSON]: as api, but fails unless the status is one of
# EXPECTED (comma-separated). Prints the body.
call() {
  local expected="$1" status
  shift
  status="$(api "$@")"
  case ",$expected," in
    *",$status,"*) cat "$RESP" ;;
    *) log "kit: $1 $2 returned $status, expected $expected:"; head -c 2000 "$RESP" >&2; log ""; return 1 ;;
  esac
}

random_hex() { openssl rand -hex "$1"; }

# Git against Forgejo as the account whose token is $TOKEN.
git_as() {
  git -c "http.extraHeader=Authorization: token ${TOKEN:?}" -c user.name=kit -c user.email=kit@noreply.localhost "$@"
}

# The project's repositories, one per line.
all_repos() { cut -f1 /etc/kit/repos.tsv; }

# repo_field REPO N: a column of repos.tsv (2 the starting level, 3 has CI, 4 a site).
repo_field() { awk -F'\t' -v r="$1" -v n="$2" '$1 == r { print $n }' /etc/kit/repos.tsv; }

has_ci() { [ "$(repo_field "$1" 3)" = 1 ]; }
is_site() { [ "$(repo_field "$1" 4)" = 1 ]; }
