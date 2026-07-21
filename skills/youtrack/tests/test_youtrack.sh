#!/usr/bin/env bash
set -uo pipefail

readonly SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HELPER="$SKILL_DIR/scripts/youtrack.sh"
readonly TEST_DIRECTORY="$(mktemp -d)"
readonly CURL_LOG="$TEST_DIRECTORY/curl.jsonl"
readonly STDOUT_FILE="$TEST_DIRECTORY/stdout"
readonly STDERR_FILE="$TEST_DIRECTORY/stderr"
RESULT_STATUS=0

cleanup() {
  rm -rf "$TEST_DIRECTORY"
}
trap cleanup EXIT

cat >"$TEST_DIRECTORY/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
output_file=""
body_file=""
url="${!#}"
data_json="[]"

while (($#)); do
  case "$1" in
    --request)
      method="$2"
      shift 2
      ;;
    --output)
      output_file="$2"
      shift 2
      ;;
    --data-binary)
      body_file="${2#@}"
      shift 2
      ;;
    --data-urlencode)
      data_json=$(jq -cn --argjson data "$data_json" --arg value "$2" '$data + [$value]')
      shift 2
      ;;
    *) shift ;;
  esac
done

body="null"
if [[ -n "$body_file" ]]; then
  body=$(<"$body_file")
fi

jq -cn \
  --arg method "$method" \
  --arg url "$url" \
  --argjson body "$body" \
  --argjson data "$data_json" \
  '{method: $method, url: $url, body: $body, data: $data}' >>"$FAKE_CURL_LOG"

case "$url" in
  *"/admin/projects"*)
    response='[{"id":"0-1","shortName":"DEMO","name":"Demo Project"}]'
    ;;
  *"/comments?"*)
    response=$(jq -cn --argjson payload "$body" \
      '{id: "4-1", text: $payload.text, author: {login: "agent"}}')
    ;;
  *"/commands?"*)
    response=$(jq -cn --argjson payload "$body" \
      '{query: $payload.query, issues: $payload.issues}')
    ;;
  *"/issues?"*)
    response=$(jq -cn --argjson payload "$body" \
      '{id: "2-1", idReadable: "DEMO-1", summary: $payload.summary, project: {shortName: "DEMO"}}')
    ;;
  *)
    response='{"idReadable":"DEMO-1","summary":"Existing issue"}'
    ;;
esac

printf '%s' "$response" >"$output_file"
printf '%s' "${FAKE_CURL_STATUS:-200}"
FAKE_CURL
chmod +x "$TEST_DIRECTORY/curl"

export PATH="$TEST_DIRECTORY:$PATH"
export YOUTRACK_URL="https://youtrack.example"
export YOUTRACK_PROJECT="DEMO"
export YOUTRACK_TOKEN="secret-token"
export FAKE_CURL_LOG="$CURL_LOG"

reset_test() {
  rm -f "$CURL_LOG" "$STDOUT_FILE" "$STDERR_FILE"
}

run_helper() {
  local input="$1"
  shift

  printf '%s' "$input" | bash "$HELPER" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
  RESULT_STATUS=${PIPESTATUS[1]}
  return 0
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local context="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected %s to be <%s>, got <%s>.\n' "$context" "$expected" "$actual" >&2
    if [[ "$context" == exit\ status* && -s "$STDERR_FILE" ]]; then
      printf 'Captured stderr:\n' >&2
      cat "$STDERR_FILE" >&2
    fi
    return 1
  fi
}

assert_stderr_contains() {
  local expected="$1"

  if ! grep -Fq "$expected" "$STDERR_FILE"; then
    printf 'Expected stderr to contain <%s>. Actual stderr:\n' "$expected" >&2
    cat "$STDERR_FILE" >&2
    return 1
  fi
}

assert_requests() {
  local filter="$1"

  if ! jq -s -e "$filter" "$CURL_LOG" >/dev/null; then
    printf 'Request assertion failed: %s\nRequests:\n' "$filter" >&2
    cat "$CURL_LOG" >&2
    return 1
  fi
}

assert_no_requests() {
  if [[ -e "$CURL_LOG" ]]; then
    printf 'Expected no requests. Requests:\n' >&2
    cat "$CURL_LOG" >&2
    return 1
  fi
}

test_posts_comment_from_standard_input() {
  reset_test
  run_helper $'Ready to ship.\n' comment 12

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 1
    and .[0].method == "POST"
    and (.[0].url | contains("/issues/DEMO-12/comments?"))
    and .[0].body == {text: "Ready to ship.\n"}
  ' || return 1
}

test_moves_issue_to_column_with_configurable_field() {
  reset_test
  export YOUTRACK_COLUMN_FIELD="Stage"
  run_helper "" move DEMO-12 "In Review"
  unset YOUTRACK_COLUMN_FIELD

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 1
    and (.[0].url | split("?")[0]) == "https://youtrack.example/youtrack/api/commands"
    and .[0].body == {query: "Stage In Review", issues: [{idReadable: "DEMO-12"}]}
  ' || return 1
}

test_assigns_issue_by_login() {
  reset_test
  run_helper "" assign DEMO-12 jane.doe

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests 'length == 1 and .[0].body.query == "for jane.doe"' || return 1
}

test_rejects_assignee_with_spaces() {
  reset_test
  run_helper "" assign DEMO-12 "Jane Doe"

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr_contains "use a YouTrack login without spaces" || return 1
  assert_no_requests || return 1
}

test_creates_issue_in_resolved_project() {
  local description=$'First line.\nContains "quotes" and \\slashes.\n'
  reset_test
  run_helper "$description" create --project DEMO --summary "API-created card"

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 2
    and .[0].method == "GET"
    and (.[0].data | contains(["query=DEMO"]))
    and .[1].method == "POST"
    and .[1].body == {
      project: {id: "0-1"},
      summary: "API-created card",
      description: "First line.\nContains \"quotes\" and \\slashes.\n"
    }
  ' || return 1
}

test_links_supported_dependency_and_hierarchy_directions() {
  local relations=(depends-on required-for parent-for subtask-of)
  local relation
  reset_test

  for relation in "${relations[@]}"; do
    run_helper "" link DEMO-12 "$relation" DEMO-34
    assert_equal 0 "$RESULT_STATUS" "exit status for $relation" || return 1
  done

  assert_requests '
    map(.body.query) == [
      "depends on DEMO-34",
      "is required for DEMO-34",
      "parent for DEMO-34",
      "subtask of DEMO-34"
    ]
    and all(.[]; .body.issues == [{idReadable: "DEMO-12"}])
  ' || return 1
}

test_rejects_self_link() {
  reset_test
  run_helper "" link DEMO-12 depends-on DEMO-12

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr_contains "Cannot link issue DEMO-12 to itself" || return 1
  assert_no_requests || return 1
}

tests=(
  test_posts_comment_from_standard_input
  test_moves_issue_to_column_with_configurable_field
  test_assigns_issue_by_login
  test_rejects_assignee_with_spaces
  test_creates_issue_in_resolved_project
  test_links_supported_dependency_and_hierarchy_directions
  test_rejects_self_link
)
failures=0

for test_name in "${tests[@]}"; do
  if "$test_name"; then
    printf 'ok - %s\n' "${test_name#test_}"
  else
    printf 'not ok - %s\n' "${test_name#test_}"
    ((failures += 1))
  fi
done

if ((failures > 0)); then
  printf '%d of %d tests failed.\n' "$failures" "${#tests[@]}" >&2
  exit 1
fi

printf '%d tests passed.\n' "${#tests[@]}"