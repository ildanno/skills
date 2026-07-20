#!/usr/bin/env bash
set -euo pipefail

readonly ISSUE_FIELDS='idReadable,summary,description,created,updated,resolved,project(shortName,name),reporter(login,fullName),updater(login,fullName),customFields(name,value(name,login,fullName,text,presentation,minutes))'
readonly COMMENT_FIELDS='id,text,created,author(login,fullName)'
BASE_URL=""
TEMP_FILES=()

cleanup() {
  if ((${#TEMP_FILES[@]} > 0)); then
    rm -f "${TEMP_FILES[@]}"
  fi
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
Usage:
  youtrack.sh read {PROJECT-NUMBER|NUMBER} [--no-comments]
  youtrack.sh comment {PROJECT-NUMBER|NUMBER} < comment.md
EOF
  exit 2
}

fail_http() {
  local operation="$1"
  local issue_id="$2"
  local http_code="$3"

  case "$http_code" in
    401) echo "Authentication failed while $operation $issue_id (HTTP 401)." >&2 ;;
    403) echo "Permission denied while $operation $issue_id (HTTP 403)." >&2 ;;
    404) echo "Issue $issue_id was not found or is not visible (HTTP 404)." >&2 ;;
    *) echo "YouTrack failed while $operation $issue_id (HTTP $http_code)." >&2 ;;
  esac
  exit 3
}

configure() {
  local missing=()
  [[ -n "${YOUTRACK_URL:-}" ]] || missing+=(YOUTRACK_URL)
  [[ -n "${YOUTRACK_TOKEN:-}" ]] || missing+=(YOUTRACK_TOKEN)

  if ((${#missing[@]} > 0)); then
    echo "Missing environment variables: ${missing[*]}." >&2
    exit 1
  fi

  BASE_URL="${YOUTRACK_URL%/}/youtrack/api"
}

resolve_issue_id() {
  local issue_reference="$1"

  if [[ "$issue_reference" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]]; then
    printf '%s\n' "$issue_reference"
    return
  fi

  if [[ "$issue_reference" =~ ^[0-9]+$ ]]; then
    if [[ -z "${YOUTRACK_PROJECT:-}" ]]; then
      echo "YOUTRACK_PROJECT is missing; it is required for a bare issue number." >&2
      exit 1
    fi
    if [[ ! "$YOUTRACK_PROJECT" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
      echo "Invalid YOUTRACK_PROJECT '$YOUTRACK_PROJECT'." >&2
      exit 2
    fi
    printf '%s-%s\n' "$YOUTRACK_PROJECT" "$issue_reference"
    return
  fi

  echo "Invalid issue '$issue_reference'; expected PROJECT-NUMBER or NUMBER." >&2
  exit 2
}

read_issue() {
  local issue_id="$1"
  shift
  local include_comments=1

  while (($#)); do
    case "$1" in
      --no-comments) include_comments=0 ;;
      *) usage ;;
    esac
    shift
  done

  local issue_file comments_file http_code
  issue_file=$(mktemp)
  comments_file=$(mktemp)
  TEMP_FILES+=("$issue_file" "$comments_file")

  http_code=$(curl --silent --show-error --output "$issue_file" --write-out '%{http_code}' \
    --header "Authorization: Bearer $YOUTRACK_TOKEN" \
    --header 'Accept: application/json' \
    "$BASE_URL/issues/$issue_id?fields=$ISSUE_FIELDS")
  [[ "$http_code" == 200 ]] || fail_http "reading" "$issue_id" "$http_code"

  if ((include_comments)); then
    http_code=$(curl --silent --show-error --output "$comments_file" --write-out '%{http_code}' \
      --header "Authorization: Bearer $YOUTRACK_TOKEN" \
      --header 'Accept: application/json' \
      "$BASE_URL/issues/$issue_id/comments?fields=$COMMENT_FIELDS")
    [[ "$http_code" == 200 ]] || fail_http "reading comments for" "$issue_id" "$http_code"
  else
    printf '[]' >"$comments_file"
  fi

  python3 - "$issue_file" "$comments_file" "$include_comments" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as issue_stream:
    issue = json.load(issue_stream)
with open(sys.argv[2], encoding="utf-8") as comments_stream:
    comments = json.load(comments_stream)

json.dump(
    {
        "issue": issue,
        "commentsIncluded": sys.argv[3] == "1",
        "comments": comments,
    },
    sys.stdout,
    ensure_ascii=False,
    indent=2,
)
print()
PY
}

post_comment() {
  local issue_id="$1"
  local comment_file payload_file response_file http_code
  comment_file=$(mktemp)
  payload_file=$(mktemp)
  response_file=$(mktemp)
  TEMP_FILES+=("$comment_file" "$payload_file" "$response_file")

  cat >"$comment_file"
  if [[ ! -s "$comment_file" ]] || ! grep -q '[^[:space:]]' "$comment_file"; then
    echo "Comment text is empty; provide it on standard input." >&2
    exit 2
  fi

  python3 - "$comment_file" "$payload_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as comment_stream:
    text = comment_stream.read()
with open(sys.argv[2], "w", encoding="utf-8") as payload_stream:
    json.dump({"text": text}, payload_stream, ensure_ascii=False)
PY

  http_code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --request POST \
    --header "Authorization: Bearer $YOUTRACK_TOKEN" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload_file" \
    "$BASE_URL/issues/$issue_id/comments?fields=$COMMENT_FIELDS")
  [[ "$http_code" == 200 ]] || fail_http "commenting on" "$issue_id" "$http_code"
  cat "$response_file"
  printf '\n'
}

main() {
  (($# >= 2)) || usage
  local operation="$1"
  local issue_reference="$2"
  local issue_id
  shift 2
  issue_id=$(resolve_issue_id "$issue_reference")
  configure

  case "$operation" in
    read) read_issue "$issue_id" "$@" ;;
    comment)
      (($# == 0)) || usage
      post_comment "$issue_id"
      ;;
    *) usage ;;
  esac
}

main "$@"