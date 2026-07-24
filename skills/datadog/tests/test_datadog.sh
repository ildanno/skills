#!/usr/bin/env bash
set -uo pipefail

readonly SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HELPER="$SKILL_DIR/scripts/datadog.sh"
readonly TEST_DIRECTORY="$(mktemp -d)"
readonly CURL_LOG="$TEST_DIRECTORY/curl.jsonl"
readonly CURL_STATE="$TEST_DIRECTORY/curl-state"
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
    --request) method="$2"; shift 2 ;;
    --output) output_file="$2"; shift 2 ;;
    --dump-header) headers_file="$2"; shift 2 ;;
    --write-out | --header) shift 2 ;;
    --config) config_file="$2"; shift 2 ;;
    --data-binary) body_file="${2#@}"; shift 2 ;;
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
api_header_present=false
app_header_present=false
bearer_header_present=false
credentials_in_environment=false
if [[ -n "$config_file" ]]; then
  config_mode=$(stat -f '%Lp' "$config_file" 2>/dev/null || stat -c '%a' "$config_file")
  grep -Fq 'DD-API-KEY: api-secret' "$config_file" && api_header_present=true
  grep -Fq 'DD-APPLICATION-KEY: app-secret' "$config_file" && app_header_present=true
  grep -Fq 'Authorization: Bearer ddpat_test_secret' "$config_file" && bearer_header_present=true
fi
if [[ -n "${DD_API_KEY+x}" || -n "${DD_APP_KEY+x}" ||
  -n "${DD_ACCESS_TOKEN+x}" || -n "${DD_TOKEN_ID+x}" ]]; then
  credentials_in_environment=true
fi

jq -cn \
  --arg method "$method" \
  --arg url "$url" \
  --argjson body "$body" \
  --argjson data "$data_json" \
  --argjson args "$args_json" \
  --arg configFile "$config_file" \
  --arg configMode "$config_mode" \
  --argjson apiHeaderPresent "$api_header_present" \
  --argjson appHeaderPresent "$app_header_present" \
  --argjson bearerHeaderPresent "$bearer_header_present" \
  --argjson credentialsInEnvironment "$credentials_in_environment" '
    {
      method:$method,
      url:$url,
      body:$body,
      data:$data,
      args:$args,
      configFile:$configFile,
      configMode:$configMode,
      apiHeaderPresent:$apiHeaderPresent,
      appHeaderPresent:$appHeaderPresent,
      bearerHeaderPresent:$bearerHeaderPresent,
      credentialsInEnvironment:$credentialsInEnvironment
    }
  ' >>"$FAKE_CURL_LOG"

status=200
if [[ -n "${FAKE_FAIL_MATCH:-}" && "$url" == *"$FAKE_FAIL_MATCH"* &&
  ( -z "${FAKE_FAIL_METHOD:-}" || "$method" == "${FAKE_FAIL_METHOD:-}" ) ]]; then
  status="${FAKE_FAIL_STATUS:-500}"
  if [[ "${FAKE_FAIL_ONCE:-false}" == true ]]; then
    count=0
    [[ ! -f "$FAKE_CURL_STATE" ]] || count=$(<"$FAKE_CURL_STATE")
    if ((count > 0)); then
      status=200
    fi
    printf '%s' "$((count + 1))" >"$FAKE_CURL_STATE"
  fi
fi

case "$url:$method" in
  *"/api/v1/validate:GET")
    response='{"valid":true}'
    ;;
  *"/api/v2/current_user:GET")
    response='{"data":{"type":"users","id":"user-1","attributes":{"handle":"agent@example.test","name":"Agent"},"relationships":{"org":{"data":{"type":"orgs","id":"org-1"}}}}}'
    ;;
  *"/api/v1/dashboard:GET")
    response='{"dashboards":[{"id":"db-1","title":"Existing Dashboard","layout_type":"ordered"},{"id":"db-2","title":"Other","layout_type":"free"}]}'
    ;;
  *"/api/v1/dashboard/db-1:GET")
    version="${FAKE_DASHBOARD_VERSION:-1}"
    response=$(jq -cn --arg version "$version" '{
      id:"db-1",
      title:"Existing Dashboard",
      layout_type:"ordered",
      widgets:[{definition:{type:"timeseries",title:"Old"}}],
      description:(if $version == "1" then "old" else "changed elsewhere" end),
      author_handle:"fixture",
      modified_at:("2026-07-24T00:00:0" + $version + "Z")
    }')
    ;;
  *"/api/v1/dashboard/db-1:PUT")
    response=$(jq -cn --argjson payload "$body" '$payload + {id:"db-1"}')
    ;;
  *"/api/v1/dashboard:POST")
    response=$(jq -cn --argjson payload "$body" '$payload + {id:"db-new"}')
    ;;
  *"/api/v1/monitor/search:GET")
    response='{"monitors":[{"id":123,"name":"Latency"}],"metadata":{"page":0,"page_count":1,"per_page":100,"total_count":1}}'
    ;;
  *"/api/v1/monitor:GET")
    response='[{"id":123,"name":"Existing Monitor","type":"metric alert","query":"avg(last_5m):avg:test.metric{*} > 1","message":"Alert"}]'
    ;;
  *"/api/v1/monitor/123:GET")
    state="${FAKE_MONITOR_STATE:-OK}"
    response=$(jq -cn --arg state "$state" '{
      id:123,
      name:"Existing Monitor",
      type:"metric alert",
      query:"avg(last_5m):avg:test.metric{*} > 1",
      message:"Alert",
      modified:"2026-07-24T00:00:00Z",
      overall_state:$state,
      overall_state_modified:"2026-07-24T00:01:00Z",
      matching_downtimes:[]
    }')
    ;;
  *"/api/v1/monitor/123:PUT")
    response=$(jq -cn --argjson payload "$body" '$payload + {id:123}')
    ;;
  *"/api/v1/monitor/123/mute:POST" | *"/api/v1/monitor/123/unmute:POST")
    response='{"id":123,"muted":true}'
    ;;
  *"/validate:POST")
    response='{}'
    ;;
  *"/api/v1/monitor:POST")
    response=$(jq -cn --argjson payload "$body" '$payload + {id:456}')
    ;;
  *"/api/v1/logs/config/pipelines:GET")
    response='[{"id":"pipe-1","name":"Existing Pipeline","filter":{"query":"source:nginx"},"processors":[]}]'
    ;;
  *"/api/v1/logs/config/pipelines/pipe-1:GET")
    response='{"id":"pipe-1","name":"Existing Pipeline","filter":{"query":"source:nginx"},"processors":[]}'
    ;;
  *"/api/v1/logs/config/pipelines:POST")
    response=$(jq -cn --argjson payload "$body" '$payload + {id:"pipe-new"}')
    ;;
  *"/api/v2/query/timeseries:POST" | *"/api/v2/query/scalar:POST")
    response='{"data":{"type":"timeseries_response","attributes":{"series":[]}}}'
    ;;
  *"/api/v1/metrics/custom.test:GET")
    response='{"description":"Old","unit":"millisecond","integration":null}'
    ;;
  *"/api/v1/metrics/custom.test:PUT")
    response="$body"
    ;;
  *"/api/v2/metrics/custom.test/tags:GET")
    response='{"data":{"type":"manage_tags","id":"custom.test","attributes":{"tags":["env"],"aggregations":[{"space":"avg","time":"avg"}]}}}'
    ;;
  *"/api/v2/metrics/custom.test/tags:PATCH" | *"/api/v2/metrics/custom.test/tags:POST")
    response="$body"
    ;;
  *"/api/v2/logs/events/search:POST")
    response='{"data":[],"meta":{"page":{"after":"next-cursor"}}}'
    ;;
  *"/api/v2/logs/analytics/aggregate:POST")
    response='{"data":{"buckets":[]}}'
    ;;
  *)
    response='{"errors":["unhandled fixture request"]}'
    status=500
    ;;
esac

if [[ "$status" != 200 ]]; then
  response='{"errors":["fixture failure"]}'
fi

{
  printf 'HTTP/1.1 %s Test\r\n' "$status"
  printf 'x-datadog-trace-id: request-123\r\n'
  [[ "$status" != 429 ]] || printf 'Retry-After: 0\r\n'
  printf '\r\n'
} >"$headers_file"
printf '%s' "$response" >"$output_file"
printf '%s' "$status"
FAKE_CURL
chmod +x "$TEST_DIRECTORY/curl"

export PATH="$TEST_DIRECTORY:$PATH"
export DD_API_KEY="api-secret"
export DD_APP_KEY="app-secret"
export DD_SITE="datadoghq.eu"
export FAKE_CURL_LOG="$CURL_LOG"
export FAKE_CURL_STATE="$CURL_STATE"

reset_test() {
  rm -f "$CURL_LOG" "$CURL_STATE" "$STDOUT_FILE" "$STDERR_FILE"
  unset FAKE_FAIL_MATCH FAKE_FAIL_METHOD FAKE_FAIL_STATUS FAKE_FAIL_ONCE
  unset FAKE_DASHBOARD_VERSION
  unset FAKE_MONITOR_STATE
  unset DD_ACCESS_TOKEN DD_TOKEN_ID
  export DD_API_KEY="api-secret"
  export DD_APP_KEY="app-secret"
  export DD_SITE="datadoghq.eu"
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
    printf 'Expected %s <%s>, got <%s>.\n' "$context" "$expected" "$actual" >&2
    [[ ! -s "$STDERR_FILE" ]] || cat "$STDERR_FILE" >&2
    return 1
  fi
}

assert_stdout() {
  local filter="$1"
  if ! jq -e "$filter" "$STDOUT_FILE" >/dev/null; then
    printf 'Output assertion failed: %s\n' "$filter" >&2
    cat "$STDOUT_FILE" >&2
    return 1
  fi
}

assert_stderr() {
  local filter="$1"
  if ! jq -e "$filter" "$STDERR_FILE" >/dev/null; then
    printf 'Error assertion failed: %s\n' "$filter" >&2
    cat "$STDERR_FILE" >&2
    return 1
  fi
}

assert_requests() {
  local filter="$1"
  if ! jq -s -e "$filter" "$CURL_LOG" >/dev/null; then
    printf 'Request assertion failed: %s\n' "$filter" >&2
    [[ ! -e "$CURL_LOG" ]] || cat "$CURL_LOG" >&2
    return 1
  fi
}

assert_no_requests() {
  [[ ! -e "$CURL_LOG" ]] || {
    printf 'Expected no requests.\n' >&2
    cat "$CURL_LOG" >&2
    return 1
  }
}

test_requires_all_environment_variables() {
  reset_test
  unset DD_APP_KEY
  run_helper "" verify
  export DD_APP_KEY="app-secret"

  assert_equal 1 "$RESULT_STATUS" "exit status" || return 1
  grep -Fq "DD_APP_KEY" "$STDERR_FILE" || return 1
  assert_no_requests
}

test_verifies_site_without_exposing_credentials() {
  reset_test
  run_helper "" verify

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_stdout '.ok and .target == "datadoghq.eu" and .meta.api_base == "https://api.datadoghq.eu"' || return 1
  assert_requests '
    length == 1
    and .[0].configMode == "600"
    and .[0].apiHeaderPresent
    and .[0].appHeaderPresent
    and (.[0].credentialsInEnvironment | not)
    and ((.[0].args | join(" ")) | contains("api-secret") | not)
    and ((.[0].args | join(" ")) | contains("app-secret") | not)
  '
}

test_authenticates_with_personal_access_token() {
  reset_test
  unset DD_API_KEY DD_APP_KEY
  export DD_ACCESS_TOKEN="ddpat_test_secret"
  export DD_TOKEN_ID="token-public-id"
  run_helper "" verify

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_stdout '
    .ok
    and .data.user.id == "user-1"
    and .data.organization_id == "org-1"
    and .meta.auth_mode == "personal_access_token"
    and .meta.token_id == "token-public-id"
  ' || return 1
  assert_requests '
    length == 1
    and (.[0].url | endswith("/api/v2/current_user"))
    and .[0].bearerHeaderPresent
    and (.[0].apiHeaderPresent | not)
    and (.[0].appHeaderPresent | not)
    and (.[0].credentialsInEnvironment | not)
    and ((.[0].args | join(" ")) | contains("ddpat_test_secret") | not)
  '
}

test_personal_access_token_requires_public_id() {
  reset_test
  unset DD_API_KEY DD_APP_KEY
  export DD_ACCESS_TOKEN="ddpat_test_secret"
  unset DD_TOKEN_ID
  run_helper "" verify

  assert_equal 1 "$RESULT_STATUS" "exit status" || return 1
  grep -Fq "DD_TOKEN_ID" "$STDERR_FILE" || return 1
  assert_no_requests
}

test_personal_access_token_is_used_for_operations() {
  reset_test
  unset DD_API_KEY DD_APP_KEY
  export DD_ACCESS_TOKEN="ddpat_test_secret"
  export DD_TOKEN_ID="token-public-id"
  run_helper "" dashboard list --limit 1

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 2
    and (.[0].url | endswith("/api/v2/current_user"))
    and (.[1].url | endswith("/api/v1/dashboard"))
    and all(.[]; .bearerHeaderPresent)
  '
}

test_pat_operation_continues_when_current_user_is_forbidden() {
  reset_test
  unset DD_API_KEY DD_APP_KEY
  export DD_ACCESS_TOKEN="ddpat_test_secret"
  export DD_TOKEN_ID="token-public-id"
  export FAKE_FAIL_MATCH="/api/v2/current_user"
  export FAKE_FAIL_METHOD=GET
  export FAKE_FAIL_STATUS=403
  run_helper "" dashboard list --limit 1

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 2
    and (.[0].url | endswith("/api/v2/current_user"))
    and (.[1].url | endswith("/api/v1/dashboard"))
  '
}

test_rejects_invalid_site_before_request() {
  reset_test
  export DD_SITE="https://api.datadoghq.eu/path"
  run_helper "" verify
  export DD_SITE="datadoghq.eu"

  assert_equal 1 "$RESULT_STATUS" "exit status" || return 1
  grep -Fq "Invalid DD_SITE" "$STDERR_FILE" || return 1
  assert_no_requests
}

test_dashboard_list_is_bounded_and_filtered() {
  reset_test
  run_helper "" dashboard list --name existing --limit 1

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_stdout '.data.total == 1 and (.data.items | length) == 1 and .meta.limit == 1' || return 1
  assert_requests 'length == 2 and .[1].method == "GET" and (.[1].url | endswith("/api/v1/dashboard"))'
}

test_logs_search_defaults_to_utc_window_and_caps_limit() {
  reset_test
  run_helper "" logs search --query "service:checkout" --limit 1000

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_stdout '
    .meta.query == "service:checkout"
    and .meta.limit == 1000
    and (.meta.from | endswith("Z"))
    and (.meta.to | endswith("Z"))
  ' || return 1
  assert_requests '
    length == 2
    and .[1].body.filter.query == "service:checkout"
    and .[1].body.page.limit == 1000
  '
}

test_rejects_log_limit_over_one_thousand() {
  reset_test
  run_helper "" logs search --query "*" --limit 1001

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr '.code == "invalid_input" and (.message | contains("maximum of 1000"))' || return 1
  assert_requests 'length == 1 and (.[0].url | endswith("/api/v1/validate"))'
}

test_blocks_duplicate_dashboard_plan() {
  reset_test
  local payload='{"title":"Existing Dashboard","layout_type":"ordered","widgets":[]}'
  local plan="$TEST_DIRECTORY/duplicate.plan.json"
  run_helper "$payload" dashboard plan-create --input - --plan-file "$plan"

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr '.code == "invalid_input" and (.message | contains("already exists"))' || return 1
  [[ ! -e "$plan" ]] || return 1
  assert_requests 'length == 2 and .[1].method == "GET"'
}

test_create_plan_does_not_write_and_apply_invalidates_plan() {
  reset_test
  local payload='{"title":"New Dashboard","layout_type":"ordered","widgets":[]}'
  local plan="$TEST_DIRECTORY/create.plan.json"
  run_helper "$payload" dashboard plan-create --input - --plan-file "$plan"

  assert_equal 0 "$RESULT_STATUS" "plan exit status" || return 1
  [[ -f "$plan" ]] || return 1
  assert_stdout '.data.action == "create" and .meta.requires_apply' || return 1
  assert_requests 'length == 2 and all(.[]; .method == "GET")' || return 1

  reset_test
  run_helper "" dashboard apply "$plan" --apply
  assert_equal 0 "$RESULT_STATUS" "apply exit status" || return 1
  [[ ! -e "$plan" ]] || return 1
  assert_stdout '.data.id == "db-new" and .meta.plan_invalidated' || return 1
  assert_requests '
    length == 3
    and .[2].method == "POST"
    and .[2].body.title == "New Dashboard"
  '
}

test_update_patch_preserves_objects_and_replaces_arrays() {
  reset_test
  local patch='{"description":"new","widgets":[]}'
  local plan="$TEST_DIRECTORY/update.plan.json"
  run_helper "$patch" dashboard plan-update db-1 --input - --plan-file "$plan"

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_stdout '
    .data.payload.title == "Existing Dashboard"
    and .data.payload.description == "new"
    and .data.payload.widgets == []
    and (.data.changed_fields | contains(["description","widgets"]))
  '
}

test_apply_rejects_concurrent_change_without_write() {
  reset_test
  local plan="$TEST_DIRECTORY/stale.plan.json"
  run_helper '{"description":"new"}' dashboard plan-update db-1 --input - --plan-file "$plan"
  assert_equal 0 "$RESULT_STATUS" "plan exit status" || return 1

  reset_test
  export FAKE_DASHBOARD_VERSION=2
  run_helper "" dashboard apply "$plan" --apply
  unset FAKE_DASHBOARD_VERSION

  assert_equal 2 "$RESULT_STATUS" "apply exit status" || return 1
  assert_stderr '.operation == "dashboard.apply" and .code == "concurrency_conflict" and (.message | contains("target changed"))' || return 1
  assert_requests 'length == 2 and all(.[]; .method == "GET")'
}

test_monitor_state_change_does_not_invalidate_config_plan() {
  reset_test
  local plan="$TEST_DIRECTORY/monitor-state.plan.json"
  run_helper '{"message":"Updated"}' monitor plan-update 123 --input - --plan-file "$plan"
  assert_equal 0 "$RESULT_STATUS" "plan exit status" || return 1

  reset_test
  export FAKE_MONITOR_STATE=Alert
  run_helper "" monitor apply "$plan" --apply
  unset FAKE_MONITOR_STATE

  assert_equal 0 "$RESULT_STATUS" "apply exit status" || return 1
  assert_stdout '.data.id == 123 and .data.message == "Updated"' || return 1
  assert_requests '
    ([.[] | select(.url | endswith("/api/v1/monitor/123/validate"))] | length) == 1
    and ([.[] | select(.method == "PUT")] | length) == 1
  '
}

test_mute_and_unmute_use_scoped_flight_plans() {
  reset_test
  local mute_plan="$TEST_DIRECTORY/mute.plan.json"
  run_helper "" monitor plan-mute 123 \
    --scope "env:production" \
    --end 2026-07-24T12:00:00Z \
    --plan-file "$mute_plan"
  assert_equal 0 "$RESULT_STATUS" "mute plan exit status" || return 1
  assert_stdout '
    .data.action == "mute"
    and .data.payload.scope == "env:production"
    and (.data.payload.end | type == "number")
  ' || return 1

  reset_test
  run_helper "" monitor apply "$mute_plan" --apply
  assert_equal 0 "$RESULT_STATUS" "mute apply exit status" || return 1
  assert_requests '
    ([.[] | select(.url | endswith("/api/v1/monitor/123/mute"))] | length) == 1
    and ([.[] | select(.url | endswith("/api/v1/monitor/123/mute"))][0].body.scope) == "env:production"
  ' || return 1

  reset_test
  local unmute_plan="$TEST_DIRECTORY/unmute.plan.json"
  run_helper "" monitor plan-unmute 123 \
    --scope "env:production" \
    --plan-file "$unmute_plan"
  assert_equal 0 "$RESULT_STATUS" "unmute plan exit status" || return 1

  reset_test
  run_helper "" monitor apply "$unmute_plan" --apply
  assert_equal 0 "$RESULT_STATUS" "unmute apply exit status" || return 1
  assert_requests '
    ([.[] | select(.url | endswith("/api/v1/monitor/123/unmute"))] | length) == 1
    and ([.[] | select(.url | endswith("/api/v1/monitor/123/unmute"))][0].body.scope) == "env:production"
  '
}

test_apply_rejects_tampered_plan_before_target_request() {
  reset_test
  local plan="$TEST_DIRECTORY/tampered.plan.json"
  run_helper '{"description":"new"}' dashboard plan-update db-1 --input - --plan-file "$plan"
  assert_equal 0 "$RESULT_STATUS" "plan exit status" || return 1

  local tampered="$TEST_DIRECTORY/tampered.tmp"
  jq '.path = "/api/v1/monitor/123"' "$plan" >"$tampered"
  mv "$tampered" "$plan"

  reset_test
  run_helper "" dashboard apply "$plan" --apply
  assert_equal 2 "$RESULT_STATUS" "apply exit status" || return 1
  assert_stderr '.message | contains("integrity check failed")' || return 1
  assert_requests 'length == 1 and (.[0].url | endswith("/api/v1/validate"))'
}

test_monitor_plan_validates_supported_type_remotely() {
  reset_test
  local payload='{"name":"New Monitor","type":"metric alert","query":"avg(last_5m):avg:test.metric{*} > 2","message":"Alert"}'
  local plan="$TEST_DIRECTORY/monitor.plan.json"
  run_helper "$payload" monitor plan-create --input - --plan-file "$plan"

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 3
    and .[1].method == "GET"
    and .[2].method == "POST"
    and (.[2].url | endswith("/api/v1/monitor/validate"))
  '
}

test_rejects_unsupported_monitor_type_before_validation() {
  reset_test
  local payload='{"name":"Composite","type":"composite","query":"1 && 2","message":"Alert"}'
  local plan="$TEST_DIRECTORY/composite.plan.json"
  run_helper "$payload" monitor plan-create --input - --plan-file "$plan"

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr '.message | contains("metric alert, log alert, or service check")' || return 1
  assert_requests 'length == 2 and all(.[]; .method == "GET")'
}

test_metrics_query_uses_v2_endpoint() {
  reset_test
  run_helper '{"data":{"type":"timeseries_request","attributes":{}}}' \
    metrics timeseries --input -

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 2
    and .[1].method == "POST"
    and (.[1].url | endswith("/api/v2/query/timeseries"))
  '
}

test_pipeline_create_uses_plan_then_apply() {
  reset_test
  local payload='{"name":"New Pipeline","filter":{"query":"source:app"},"processors":[]}'
  local plan="$TEST_DIRECTORY/pipeline.plan.json"
  run_helper "$payload" pipeline plan-create --input - --plan-file "$plan"
  assert_equal 0 "$RESULT_STATUS" "plan exit status" || return 1
  assert_requests 'length == 2 and all(.[]; .method == "GET")' || return 1

  reset_test
  run_helper "" pipeline apply "$plan" --apply
  assert_equal 0 "$RESULT_STATUS" "apply exit status" || return 1
  assert_stdout '.data.id == "pipe-new"' || return 1
  assert_requests '
    ([.[] | select(.method == "POST" and (.url | endswith("/api/v1/logs/config/pipelines")))] | length) == 1
  '
}

test_metric_metadata_patch_preserves_existing_fields() {
  reset_test
  local plan="$TEST_DIRECTORY/metadata.plan.json"
  run_helper '{"description":"Updated"}' \
    metrics metadata plan-update custom.test --input - --plan-file "$plan"
  assert_equal 0 "$RESULT_STATUS" "plan exit status" || return 1
  assert_stdout '.data.payload.description == "Updated" and .data.payload.unit == "millisecond"' || return 1

  reset_test
  run_helper "" metrics metadata apply "$plan" --apply
  assert_equal 0 "$RESULT_STATUS" "apply exit status" || return 1
  assert_requests '
    ([.[] | select(.method == "PUT" and (.url | endswith("/api/v1/metrics/custom.test")))] | length) == 1
  '
}

test_metric_tag_update_uses_patch() {
  reset_test
  local patch='{"data":{"type":"manage_tags","id":"custom.test","attributes":{"tags":["env","service"]}}}'
  local plan="$TEST_DIRECTORY/tag-update.plan.json"
  run_helper "$patch" metrics tags plan-update custom.test --input - --plan-file "$plan"
  assert_equal 0 "$RESULT_STATUS" "plan exit status" || return 1

  reset_test
  run_helper "" metrics tags apply "$plan" --apply
  assert_equal 0 "$RESULT_STATUS" "apply exit status" || return 1
  assert_requests '
    ([.[] | select(.method == "PATCH" and (.url | endswith("/api/v2/metrics/custom.test/tags")))] | length) == 1
  '
}

test_logs_aggregate_adds_default_utc_window() {
  reset_test
  run_helper '{"filter":{"query":"service:checkout"},"compute":[{"aggregation":"count"}]}' \
    logs aggregate --input -
  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 2
    and .[1].body.filter.query == "service:checkout"
    and (.[1].body.filter.from | endswith("Z"))
    and (.[1].body.filter.to | endswith("Z"))
  '
}

test_metric_tag_id_must_match_target() {
  reset_test
  local payload='{"data":{"type":"manage_tags","id":"custom.other","attributes":{"tags":["env"]}}}'
  local plan="$TEST_DIRECTORY/tags.plan.json"
  run_helper "$payload" metrics tags plan-create custom.test --input - --plan-file "$plan"

  assert_equal 2 "$RESULT_STATUS" "exit status" || return 1
  assert_stderr '.message | contains("does not match")'
}

test_export_removes_dashboard_response_fields() {
  reset_test
  run_helper "" dashboard export db-1

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_stdout '
    .title == "Existing Dashboard"
    and (has("id") | not)
    and (has("author_handle") | not)
    and (has("modified_at") | not)
  '
}

test_read_retries_once_after_rate_limit() {
  reset_test
  export FAKE_FAIL_MATCH="/api/v1/dashboard"
  export FAKE_FAIL_METHOD=GET
  export FAKE_FAIL_STATUS=429
  export FAKE_FAIL_ONCE=true
  run_helper "" dashboard list

  assert_equal 0 "$RESULT_STATUS" "exit status" || return 1
  assert_requests '
    length == 3
    and (.[1].url | endswith("/api/v1/dashboard"))
    and (.[2].url | endswith("/api/v1/dashboard"))
  '
}

test_write_is_not_retried() {
  reset_test
  local plan="$TEST_DIRECTORY/write-failure.plan.json"
  run_helper '{"description":"new"}' dashboard plan-update db-1 --input - --plan-file "$plan"
  assert_equal 0 "$RESULT_STATUS" "plan exit status" || return 1

  reset_test
  export FAKE_FAIL_MATCH="/api/v1/dashboard/db-1"
  export FAKE_FAIL_METHOD=PUT
  export FAKE_FAIL_STATUS=500
  run_helper "" dashboard apply "$plan" --apply

  assert_equal 3 "$RESULT_STATUS" "apply exit status" || return 1
  assert_stderr '.status == 500 and .request_id == "request-123"' || return 1
  [[ -f "$plan" ]] || return 1
  assert_requests '([.[] | select(.method == "PUT")] | length) == 1'
}

run_test() {
  local name="$1"
  if "$name"; then
    printf 'ok - %s\n' "${name#test_}"
    return 0
  fi
  printf 'not ok - %s\n' "${name#test_}" >&2
  return 1
}

tests=(
  test_requires_all_environment_variables
  test_verifies_site_without_exposing_credentials
  test_authenticates_with_personal_access_token
  test_personal_access_token_requires_public_id
  test_personal_access_token_is_used_for_operations
  test_pat_operation_continues_when_current_user_is_forbidden
  test_rejects_invalid_site_before_request
  test_dashboard_list_is_bounded_and_filtered
  test_logs_search_defaults_to_utc_window_and_caps_limit
  test_rejects_log_limit_over_one_thousand
  test_blocks_duplicate_dashboard_plan
  test_create_plan_does_not_write_and_apply_invalidates_plan
  test_update_patch_preserves_objects_and_replaces_arrays
  test_apply_rejects_concurrent_change_without_write
  test_monitor_state_change_does_not_invalidate_config_plan
  test_mute_and_unmute_use_scoped_flight_plans
  test_apply_rejects_tampered_plan_before_target_request
  test_monitor_plan_validates_supported_type_remotely
  test_rejects_unsupported_monitor_type_before_validation
  test_metrics_query_uses_v2_endpoint
  test_pipeline_create_uses_plan_then_apply
  test_metric_metadata_patch_preserves_existing_fields
  test_metric_tag_update_uses_patch
  test_logs_aggregate_adds_default_utc_window
  test_metric_tag_id_must_match_target
  test_export_removes_dashboard_response_fields
  test_read_retries_once_after_rate_limit
  test_write_is_not_retried
)

failures=0
for test_name in "${tests[@]}"; do
  run_test "$test_name" || ((failures += 1))
done

if ((failures > 0)); then
  printf '%d of %d tests failed.\n' "$failures" "${#tests[@]}" >&2
  exit 1
fi
printf '%d tests passed.\n' "${#tests[@]}"
