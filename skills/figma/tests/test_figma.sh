#!/usr/bin/env bash
set -uo pipefail

readonly SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HELPER="$SKILL_DIR/scripts/figma.sh"
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
headers_file=""
body_file=""
config_file=""
url="${!#}"
data_json="[]"
args_json="[]"

for argument in "$@"; do
  args_json=$(jq -cn --argjson args "$args_json" --arg value "$argument" '$args + [$value]')
done

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
    --dump-header)
      headers_file="$2"
      shift 2
      ;;
    --write-out | --header)
      shift 2
      ;;
    --config)
      config_file="$2"
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

config_mode=""
auth_header_present=false
token_environment_present=false
if [[ -n "$config_file" ]]; then
  config_mode=$(stat -f '%Lp' "$config_file" 2>/dev/null || stat -c '%a' "$config_file")
  if grep -Fq 'X-Figma-Token: secret-token' "$config_file"; then
    auth_header_present=true
  fi
fi
if [[ -n "${FIGMA_TOKEN+x}" ]]; then
  token_environment_present=true
fi

jq -cn \
  --arg method "$method" \
  --arg url "$url" \
  --argjson body "$body" \
  --argjson data "$data_json" \
  --argjson args "$args_json" \
  --arg configFile "$config_file" \
  --arg configMode "$config_mode" \
  --argjson authHeaderPresent "$auth_header_present" \
  --argjson tokenEnvironmentPresent "$token_environment_present" \
  '{
    method: $method,
    url: $url,
    body: $body,
    data: $data,
    args: $args,
    configFile: $configFile,
    configMode: $configMode,
    authHeaderPresent: $authHeaderPresent,
    tokenEnvironmentPresent: $tokenEnvironmentPresent
  }' >>"$FAKE_CURL_LOG"

status="${FAKE_CURL_STATUS:-200}"
if [[ -n "$headers_file" ]]; then
  {
    printf 'HTTP/1.1 %s Test\r\n' "$status"
    [[ "$status" != 429 ]] || printf 'Retry-After: 37\r\n'
    printf '\r\n'
  } >"$headers_file"
fi

if [[ "$status" != 200 ]]; then
  response='{"err":"fixture failure"}'
else
  case "$url:$method" in
    *"/v1/me:GET")
      response='{"id":"user-1","email":"hidden@example.com","handle":"Agent","img_url":"https://example.test/avatar"}'
      ;;
    *"/comments:GET")
      response='{"comments":[{"id":"root-1","message":"Root","user":{"id":"user-2","handle":"Reviewer","img_url":""},"created_at":"2026-01-01T00:00:00Z","resolved_at":null,"client_meta":{"x":1,"y":2},"order_id":"1","reactions":[]},{"id":"reply-1","parent_id":"root-1","message":"Reply","user":{"id":"user-1","handle":"Agent","img_url":""},"created_at":"2026-01-02T00:00:00Z","resolved_at":null,"client_meta":{"x":1,"y":2},"order_id":null,"reactions":[]}]}'
      ;;
    *"/comments:POST")
      response=$(jq -cn --argjson payload "$body" \
        '{id: "created-1", message: $payload.message, parent_id: ($payload.comment_id // null), client_meta: ($payload.client_meta // null), user: {id: "user-1", handle: "Agent"}}')
      ;;
    *"/nodes:GET")
      response='{"name":"Fixture","nodes":{"12:34":{"document":{"id":"12:34","name":"Frame","type":"FRAME"}}}}'
      ;;
    *"/files/"*":GET")
      response='{"name":"Fixture","document":{"id":"0:0","name":"Document","type":"DOCUMENT","children":[]}}'
      ;;
    *)
      response='{"err":"unhandled fixture request"}'
      status=500
      ;;
  esac
fi

printf '%s' "$response" >"$output_file"
printf '%s' "$status"
FAKE_CURL
chmod +x "$TEST_DIRECTORY/curl"

export PATH="$TEST_DIRECTORY:$PATH"
export FIGMA_TOKEN="secret-token"
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
    [[ ! -s "$STDERR_FILE" ]] || {
      printf 'Captured stderr:\n' >&2
      cat "$STDERR_FILE" >&2
    }
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
    [[ ! -e "$CURL_LOG" ]] || cat "$CURL_LOG" >&2
    return 1
  fi
}

assert_stdout() {
  local filter="$1"

  if ! jq -e "$filter" "$STDOUT_FILE" >/dev/null; then
    printf 'Output assertion failed: %s\nOutput:\n' "$filter" >&2
    cat "$STDOUT_FILE" >&2
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

test_requires_token_without_making_request() {
  reset_test
  unset FIGMA_TOKEN
  run_helper "" verify
  export FIGMA_TOKEN="secret-token"

  assert_equal 1 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr_contains "Missing environment variable: FIGMA_TOKEN." || return 1
  assert_no_requests || return 1
}

test_rejects_newline_in_token() {
  reset_test
  export FIGMA_TOKEN=$'secret\ninjected'
  run_helper "" verify
  export FIGMA_TOKEN="secret-token"

  assert_equal 1 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr_contains "FIGMA_TOKEN contains a newline or carriage return." || return 1
  assert_no_requests || return 1
}

test_verifies_identity_without_exposing_token_or_email() {
  reset_test
  run_helper "" verify

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_stdout '. == {id: "user-1", handle: "Agent"}' || return 1
  assert_requests '
    length == 1
    and .[0].method == "GET"
    and .[0].url == "https://api.figma.com/v1/me"
    and .[0].configMode == "600"
    and .[0].authHeaderPresent
    and (.[0].tokenEnvironmentPresent | not)
    and ((.[0].args | join(" ")) | contains("secret-token") | not)
  ' || return 1

  local config_file
  config_file=$(jq -r '.configFile' "$CURL_LOG")
  [[ ! -e "$config_file" ]] || {
    echo "Expected temporary curl config to be removed." >&2
    return 1
  }
}

test_reads_supported_figma_urls_at_default_depth() {
  reset_test
  local file_type
  for file_type in design file proto board; do
    run_helper "" read-file "https://www.figma.com/$file_type/AbC_123/Example"
    assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  done

  assert_requests '
    length == 4
    and all(.[];
      .url == "https://api.figma.com/v1/files/AbC_123"
      and .data == ["depth=2"]
    )
  ' || return 1
}

test_accepts_figma_url_with_empty_query() {
  reset_test
  run_helper "" read-file "https://www.figma.com/design/AbC123/Example?"

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 1
    and .[0].url == "https://api.figma.com/v1/files/AbC123"
    and .[0].data == ["depth=2"]
  ' || return 1
}

test_reads_node_from_url_and_normalizes_id() {
  reset_test
  run_helper "" read-nodes \
    "https://www.figma.com/design/AbC123/Example?node-id=12-34&t=fixture"

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 1
    and .[0].url == "https://api.figma.com/v1/files/AbC123/nodes"
    and .[0].data == ["ids=12:34"]
  ' || return 1
}

test_reads_node_batch_with_optional_depth() {
  reset_test
  run_helper "" read-nodes AbC123 "12-34, 56:78" --depth 3

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 1
    and .[0].data == ["ids=12:34,56:78", "depth=3"]
  ' || return 1
}

test_rejects_invalid_depth_before_request() {
  reset_test
  run_helper "" read-file AbC123 --depth 0

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr_contains "expected a positive integer" || return 1
  assert_no_requests || return 1
}

test_rejects_non_figma_url_before_request() {
  reset_test
  run_helper "" read-file "https://evil.example/design/AbC123/Example"

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr_contains "expected www.figma.com" || return 1
  assert_no_requests || return 1
}

test_reads_all_comments_as_markdown() {
  reset_test
  run_helper "" read-comments \
    "https://www.figma.com/board/AbC123/Example"

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 1
    and .[0].method == "GET"
    and .[0].url == "https://api.figma.com/v1/files/AbC123/comments"
    and .[0].data == ["as_md=true"]
  ' || return 1
}

test_posts_general_comment_from_standard_input() {
  reset_test
  run_helper $'First line.\nSecond line.\n' add-comment AbC123

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 1
    and .[0].method == "POST"
    and .[0].body == {message: "First line.\nSecond line.\n"}
  ' || return 1
}

test_posts_anchored_comment_with_frame_offset() {
  reset_test
  run_helper $'Pinned.\n' add-comment \
    "https://www.figma.com/design/AbC123/Example?node-id=12-34" \
    --offset-x 20.5 \
    --offset-y -4

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 1
    and .[0].body == {
      message: "Pinned.\n",
      client_meta: {
        node_id: "12:34",
        node_offset: {x: 20.5, y: -4}
      }
    }
  ' || return 1
}

test_requires_offsets_for_url_node_before_request() {
  reset_test
  run_helper $'Pinned.\n' add-comment \
    "https://www.figma.com/design/AbC123/Example?node-id=12-34"

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr_contains "Anchored comments require --offset-x and --offset-y." || return 1
  assert_no_requests || return 1
}

test_resolves_reply_to_root_comment() {
  reset_test
  run_helper $'Resolved.\n' reply-comment AbC123 reply-1

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 2
    and .[0].method == "GET"
    and .[0].data == ["as_md=true"]
    and .[1].method == "POST"
    and .[1].body == {
      message: "Resolved.\n",
      comment_id: "root-1"
    }
  ' || return 1
}

test_unknown_reply_target_does_not_post() {
  reset_test
  run_helper $'Resolved.\n' reply-comment AbC123 missing-1

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr_contains "Comment 'missing-1' was not found uniquely" || return 1
  assert_requests 'length == 1 and .[0].method == "GET"' || return 1
}

test_surfaces_rate_limit_without_retry() {
  reset_test
  export FAKE_CURL_STATUS=429
  run_helper "" verify
  unset FAKE_CURL_STATUS

  assert_equal 3 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr_contains "HTTP 429" || return 1
  assert_stderr_contains "Retry-After: 37s." || return 1
  assert_requests 'length == 1' || return 1
}

run_test() {
  local name="$1"
  local function_name="$2"

  if "$function_name"; then
    printf 'ok - %s\n' "$name"
    return 0
  fi
  printf 'not ok - %s\n' "$name" >&2
  return 1
}

failures=0
run_test "requires_token_without_making_request" test_requires_token_without_making_request || ((failures += 1))
run_test "rejects_newline_in_token" test_rejects_newline_in_token || ((failures += 1))
run_test "verifies_identity_without_exposing_token_or_email" test_verifies_identity_without_exposing_token_or_email || ((failures += 1))
run_test "reads_supported_figma_urls_at_default_depth" test_reads_supported_figma_urls_at_default_depth || ((failures += 1))
run_test "accepts_figma_url_with_empty_query" test_accepts_figma_url_with_empty_query || ((failures += 1))
run_test "reads_node_from_url_and_normalizes_id" test_reads_node_from_url_and_normalizes_id || ((failures += 1))
run_test "reads_node_batch_with_optional_depth" test_reads_node_batch_with_optional_depth || ((failures += 1))
run_test "rejects_invalid_depth_before_request" test_rejects_invalid_depth_before_request || ((failures += 1))
run_test "rejects_non_figma_url_before_request" test_rejects_non_figma_url_before_request || ((failures += 1))
run_test "reads_all_comments_as_markdown" test_reads_all_comments_as_markdown || ((failures += 1))
run_test "posts_general_comment_from_standard_input" test_posts_general_comment_from_standard_input || ((failures += 1))
run_test "posts_anchored_comment_with_frame_offset" test_posts_anchored_comment_with_frame_offset || ((failures += 1))
run_test "requires_offsets_for_url_node_before_request" test_requires_offsets_for_url_node_before_request || ((failures += 1))
run_test "resolves_reply_to_root_comment" test_resolves_reply_to_root_comment || ((failures += 1))
run_test "unknown_reply_target_does_not_post" test_unknown_reply_target_does_not_post || ((failures += 1))
run_test "surfaces_rate_limit_without_retry" test_surfaces_rate_limit_without_retry || ((failures += 1))

if ((failures > 0)); then
  printf '%s test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '16 tests passed.\n'
