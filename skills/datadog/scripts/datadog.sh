#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_LIST_LIMIT=100
readonly MAX_LIST_LIMIT=100
readonly DEFAULT_LOG_LIMIT=100
readonly MAX_LOG_LIMIT=1000
readonly PLAN_VERSION=1

API_BASE=""
AUTH_CONFIG=""
AUTH_MODE=""
TOKEN_ID=""
RESPONSE_FILE=""
HEADERS_FILE=""
VERIFY_FILE=""
LAST_HTTP_STATUS=""
ALLOW_FORBIDDEN=false
TEMP_FILES=()

cleanup() {
  local status=$?
  if ((${#TEMP_FILES[@]} > 0)); then
    rm -f "${TEMP_FILES[@]}"
  fi
  return "$status"
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
Usage:
  datadog.sh verify

  datadog.sh dashboard list [--name NAME] [--limit N] [--page N] [--raw]
  datadog.sh dashboard get ID [--raw]
  datadog.sh dashboard export ID
  datadog.sh dashboard plan-create --input FILE|- --plan-file FILE [--allow-duplicate]
  datadog.sh dashboard plan-update ID --input FILE|- --plan-file FILE [--replace]
  datadog.sh dashboard apply PLAN_FILE --apply

  datadog.sh monitor list [--query QUERY] [--limit N] [--page N] [--raw]
  datadog.sh monitor get ID [--raw]
  datadog.sh monitor export ID
  datadog.sh monitor plan-create --input FILE|- --plan-file FILE [--allow-duplicate]
  datadog.sh monitor plan-update ID --input FILE|- --plan-file FILE [--replace]
  datadog.sh monitor plan-mute ID --scope SCOPE (--end ISO_UTC|--indefinite) --plan-file FILE
  datadog.sh monitor plan-unmute ID --scope SCOPE --plan-file FILE
  datadog.sh monitor apply PLAN_FILE --apply

  datadog.sh pipeline list [--name NAME] [--limit N] [--offset N] [--raw]
  datadog.sh pipeline get ID [--raw]
  datadog.sh pipeline export ID
  datadog.sh pipeline plan-create --input FILE|- --plan-file FILE [--allow-duplicate]
  datadog.sh pipeline plan-update ID --input FILE|- --plan-file FILE [--replace]
  datadog.sh pipeline apply PLAN_FILE --apply

  datadog.sh metrics timeseries --input FILE|- [--raw]
  datadog.sh metrics scalar --input FILE|- [--raw]
  datadog.sh metrics metadata get NAME [--raw]
  datadog.sh metrics metadata export NAME
  datadog.sh metrics metadata plan-update NAME --input FILE|- --plan-file FILE [--replace]
  datadog.sh metrics metadata apply PLAN_FILE --apply
  datadog.sh metrics tags get NAME [--raw]
  datadog.sh metrics tags export NAME
  datadog.sh metrics tags plan-create NAME --input FILE|- --plan-file FILE
  datadog.sh metrics tags plan-update NAME --input FILE|- --plan-file FILE [--replace]
  datadog.sh metrics tags apply PLAN_FILE --apply

  datadog.sh logs search --query QUERY [--from ISO_UTC] [--to ISO_UTC] [--limit N] [--cursor CURSOR] [--raw]
  datadog.sh logs aggregate --input FILE|- [--raw]
EOF
  exit 2
}

new_temp() {
  local target="$1"
  local value
  value=$(mktemp)
  chmod 600 "$value"
  TEMP_FILES+=("$value")
  printf -v "$target" '%s' "$value"
}

emit_error() {
  local status="$1"
  local operation="$2"
  local code="$3"
  local message="$4"
  local request_id="${5:-}"

  jq -cn \
    --arg operation "$operation" \
    --arg status "$status" \
    --arg code "$code" \
    --arg message "$message" \
    --arg request_id "$request_id" '
      {
        ok: false,
        operation: $operation,
        status: ($status | if test("^[0-9]+$") then tonumber else . end),
        code: $code,
        message: $message
      }
      + if $request_id == "" then {} else {request_id: $request_id} end
    ' >&2
}

die() {
  local message="$1"
  local operation="${2:-validation}"
  emit_error 2 "$operation" invalid_input "$message"
  exit 2
}

require_command() {
  command -v "$1" >/dev/null || {
    printf 'Required command not found: %s.\n' "$1" >&2
    exit 1
  }
}

validate_secret() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || {
    printf 'Missing environment variable: %s.\n' "$name" >&2
    exit 1
  }
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    printf '%s contains a newline or carriage return.\n' "$name" >&2
    exit 1
  fi
}

escape_curl_config() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

configure() {
  require_command curl
  require_command jq

  [[ -n "${DD_SITE:-}" ]] || {
    printf 'Missing environment variable: DD_SITE.\n' >&2
    exit 1
  }
  if [[ "$DD_SITE" == *$'\n'* || "$DD_SITE" == *$'\r'* ]]; then
    printf 'DD_SITE contains a newline or carriage return.\n' >&2
    exit 1
  fi
  case "$DD_SITE" in
    datadoghq.com | datadoghq.eu | ddog-gov.com) ;;
    *.datadoghq.com | *.ddog-gov.com)
      [[ "$DD_SITE" != app.* && "$DD_SITE" != api.* ]] || {
        printf 'Invalid DD_SITE %q; use the site suffix, not an app or API hostname.\n' "$DD_SITE" >&2
        exit 1
      }
      ;;
    *)
      printf 'Invalid DD_SITE %q; use a Datadog site such as datadoghq.eu.\n' "$DD_SITE" >&2
      exit 1
      ;;
  esac

  API_BASE="https://api.$DD_SITE"
  new_temp AUTH_CONFIG
  if [[ -n "${DD_ACCESS_TOKEN:-}" ]]; then
    validate_secret DD_ACCESS_TOKEN
    validate_secret DD_TOKEN_ID
    [[ "$DD_ACCESS_TOKEN" == ddpat_* ]] || {
      printf 'DD_ACCESS_TOKEN is not a Datadog Personal Access Token; expected the ddpat_ prefix.\n' >&2
      exit 1
    }
    AUTH_MODE="personal_access_token"
    TOKEN_ID="$DD_TOKEN_ID"
    printf 'header = "Authorization: Bearer %s"\n' \
      "$(escape_curl_config "$DD_ACCESS_TOKEN")" >"$AUTH_CONFIG"
  else
    validate_secret DD_API_KEY
    validate_secret DD_APP_KEY
    AUTH_MODE="api_application_keys"
    printf 'header = "DD-API-KEY: %s"\n' \
      "$(escape_curl_config "$DD_API_KEY")" >"$AUTH_CONFIG"
    printf 'header = "DD-APPLICATION-KEY: %s"\n' \
      "$(escape_curl_config "$DD_APP_KEY")" >>"$AUTH_CONFIG"
  fi
  unset DD_ACCESS_TOKEN DD_TOKEN_ID DD_API_KEY DD_APP_KEY
}

header_value() {
  local header_name="$1"
  awk -v target="$header_name" '
    BEGIN { IGNORECASE = 1 }
    {
      name = $1
      sub(/:$/, "", name)
      if (tolower(name) == tolower(target)) {
        $1 = ""
        sub(/^[[:space:]]+/, "")
        gsub(/\r$/, "")
        value = $0
      }
    }
    END { print value }
  ' "$HEADERS_FILE"
}

http_failure() {
  local operation="$1"
  local status="$2"
  local diagnostic=""
  local request_id=""

  if [[ -s "$RESPONSE_FILE" ]] && jq -e . "$RESPONSE_FILE" >/dev/null 2>&1; then
    diagnostic=$(jq -r '
      if type == "object" then
        (
          .errors[0]
          // .error
          // .message
          // .errors
          // empty
          | tostring
          | gsub("\\n"; " ")
        )
      else empty end
    ' "$RESPONSE_FILE")
  fi
  request_id=$(header_value x-datadog-trace-id)
  [[ -n "$request_id" ]] || request_id=$(header_value x-request-id)

  local code message
  case "$status" in
    400) code=invalid_request; message="Datadog rejected the request." ;;
    401) code=authentication_failed; message="Datadog authentication failed." ;;
    403) code=permission_denied; message="The Datadog credential lacks permission for this operation." ;;
    404) code=not_found; message="The Datadog resource was not found or is not visible." ;;
    409) code=conflict; message="Datadog reported a conflicting resource or state." ;;
    429) code=rate_limited; message="Datadog rate limited the request." ;;
    5??) code=datadog_unavailable; message="Datadog failed while processing the request." ;;
    *) code=unexpected_response; message="Datadog returned an unexpected HTTP response." ;;
  esac
  [[ -z "$diagnostic" ]] || message="$message $diagnostic"
  emit_error "$status" "$operation" "$code" "$message" "$request_id"
  exit 3
}

api_request() {
  local method="$1"
  local operation="$2"
  local retryable="$3"
  shift 3

  local attempt=0
  local http_code curl_status retry_after delay
  while :; do
    new_temp RESPONSE_FILE
    new_temp HEADERS_FILE
    if http_code=$(curl \
      --silent \
      --show-error \
      --output "$RESPONSE_FILE" \
      --dump-header "$HEADERS_FILE" \
      --write-out '%{http_code}' \
      --config "$AUTH_CONFIG" \
      --request "$method" \
      --header 'Accept: application/json' \
      "$@"); then
      curl_status=0
    else
      curl_status=$?
    fi

    if ((curl_status != 0)); then
      emit_error "$curl_status" "$operation" transport_failure \
        "curl failed while contacting Datadog."
      exit 3
    fi
    LAST_HTTP_STATUS="$http_code"
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      if [[ -s "$RESPONSE_FILE" ]] && ! jq -e . "$RESPONSE_FILE" >/dev/null 2>&1; then
        emit_error "$http_code" "$operation" invalid_json \
          "Datadog returned a non-JSON success response."
        exit 3
      fi
      return
    fi
    if [[ "$http_code" == 403 && "$ALLOW_FORBIDDEN" == true ]]; then
      return
    fi

    if [[ "$retryable" == true && "$attempt" == 0 &&
      ("$http_code" == 429 || "$http_code" == 5??) ]]; then
      attempt=1
      retry_after=$(header_value retry-after)
      delay=1
      [[ "$retry_after" =~ ^[0-9]+$ ]] && delay="$retry_after"
      sleep "$delay"
      continue
    fi
    http_failure "$operation" "$http_code"
  done
}

verify_auth() {
  new_temp VERIFY_FILE
  if [[ "$AUTH_MODE" == personal_access_token ]]; then
    ALLOW_FORBIDDEN=true
    api_request GET verify true "$API_BASE/api/v2/current_user"
    ALLOW_FORBIDDEN=false
    if [[ "$LAST_HTTP_STATUS" == 403 ]]; then
      jq -n '{
        identity_available:false,
        identity_reason:"current_user scope unavailable; target operation performs authorization"
      }' >"$VERIFY_FILE"
      return
    fi
    if ! jq -e '.data.id | type == "string" and length > 0' "$RESPONSE_FILE" >/dev/null; then
      emit_error 401 verify authentication_failed \
        "Datadog did not validate the Personal Access Token."
      exit 3
    fi
    jq '{
      user: {
        id: .data.id,
        handle: (.data.attributes.handle // null),
        name: (.data.attributes.name // null)
      },
      organization_id: (
        .data.relationships.org.data.id
        // .data.relationships.organization.data.id
        // null
      )
    }' "$RESPONSE_FILE" >"$VERIFY_FILE"
  else
    api_request GET verify true "$API_BASE/api/v1/validate"
    if ! jq -e '.valid == true' "$RESPONSE_FILE" >/dev/null; then
      emit_error 401 verify authentication_failed "Datadog did not validate the API key."
      exit 3
    fi
    jq '{valid}' "$RESPONSE_FILE" >"$VERIFY_FILE"
  fi
}

emit_success() {
  local operation="$1"
  local target="$2"
  local data_file="$3"
  local meta_json="${4:-}"
  [[ -n "$meta_json" ]] || meta_json='{}'

  jq -n \
    --arg operation "$operation" \
    --arg target "$target" \
    --slurpfile data "$data_file" \
    --argjson meta "$meta_json" '
      {
        ok: true,
        operation: $operation,
        target: $target,
        data: ($data[0] // null),
        meta: $meta
      }
    '
}

emit_read() {
  local operation="$1"
  local target="$2"
  local raw="$3"
  local meta_json="${4:-}"
  [[ -n "$meta_json" ]] || meta_json='{}'
  if [[ "$raw" == true ]]; then
    cat "$RESPONSE_FILE"
    printf '\n'
  else
    emit_success "$operation" "$target" "$RESPONSE_FILE" "$meta_json"
  fi
}

validate_limit() {
  local value="$1"
  local maximum="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
    die "Limit must be a positive integer."
  ((value <= maximum)) ||
    die "Limit $value exceeds the maximum of $maximum."
}

validate_offset() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "Offset and page values must be non-negative integers."
}

validate_id() {
  [[ "$2" =~ ^[A-Za-z0-9._:-]+$ ]] ||
    die "Invalid $1 identifier '$2'."
}

validate_metric_name() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]] ||
    die "Invalid metric name '$1'."
}

validate_iso_utc() {
  [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] ||
    die "Invalid $1 '$2'; expected ISO 8601 UTC ending in Z."
}

utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

utc_24_hours_ago() {
  if date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
    return
  fi
  date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ'
}

read_json_input() {
  local target="$1"
  local input_source="$2"
  new_temp "$target"
  if [[ "$input_source" == "-" ]]; then
    cat >"${!target}"
  else
    [[ -f "$input_source" ]] || die "Input file '$input_source' does not exist."
    cat "$input_source" >"${!target}"
  fi
  jq -e 'type == "object"' "${!target}" >/dev/null 2>&1 ||
    die "Input must be a JSON object."
}

canonical_hash() {
  local file="$1"
  local canonical hash
  canonical=$(mktemp)
  TEMP_FILES+=("$canonical")
  jq -S -c . "$file" >"$canonical"
  if command -v shasum >/dev/null; then
    hash=$(shasum -a 256 "$canonical")
  elif command -v sha256sum >/dev/null; then
    hash=$(sha256sum "$canonical")
  else
    printf 'Required command not found: shasum or sha256sum.\n' >&2
    exit 1
  fi
  printf '%s\n' "${hash%% *}"
}

resource_hash() {
  local resource="$1"
  local input_file="$2"
  local sanitized
  new_temp sanitized
  sanitize_resource "$resource" "$input_file" "$sanitized"
  canonical_hash "$sanitized"
}

seal_plan() {
  local plan_file="$1"
  local unsigned sealed integrity
  new_temp unsigned
  new_temp sealed
  jq 'del(.integrity)' "$plan_file" >"$unsigned"
  integrity=$(canonical_hash "$unsigned")
  jq --arg integrity "$integrity" '. + {integrity:$integrity}' "$unsigned" >"$sealed"
  cat "$sealed" >"$plan_file"
}

sanitize_resource() {
  local resource="$1"
  local input_file="$2"
  local output_file="$3"
  case "$resource" in
    dashboard)
      jq 'del(.id, .author_handle, .author_name, .created_at, .modified_at, .url)' \
        "$input_file" >"$output_file"
      ;;
    monitor)
      jq 'del(
        .id, .creator, .created, .modified, .overall_state,
        .overall_state_modified, .matching_downtimes, .deleted, .multi
      )' "$input_file" >"$output_file"
      ;;
    pipeline) jq 'del(.id)' "$input_file" >"$output_file" ;;
    metric-metadata | metric-tags) jq '.' "$input_file" >"$output_file" ;;
    *) die "Unsupported resource '$resource'." ;;
  esac
}

validate_payload() {
  local resource="$1"
  local payload_file="$2"
  case "$resource" in
    dashboard)
      jq -e '
        (.title | type == "string" and test("\\S"))
        and (.layout_type | type == "string")
        and (.widgets | type == "array")
      ' "$payload_file" >/dev/null ||
        die "Dashboard payload requires non-empty title, layout_type, and widgets array."
      ;;
    monitor)
      jq -e '
        (.name | type == "string" and test("\\S"))
        and (.query | type == "string" and test("\\S"))
        and (.message | type == "string")
        and (.type == "metric alert" or .type == "log alert" or .type == "service check")
      ' "$payload_file" >/dev/null ||
        die "Monitor payload must be a metric alert, log alert, or service check with name, query, and message."
      ;;
    pipeline)
      jq -e '
        (.name | type == "string" and test("\\S"))
        and (.filter | type == "object")
        and (.processors | type == "array")
      ' "$payload_file" >/dev/null ||
        die "Pipeline payload requires non-empty name, filter object, and processors array."
      ;;
    metric-metadata)
      jq -e 'type == "object" and length > 0' "$payload_file" >/dev/null ||
        die "Metric metadata payload must be a non-empty object."
      ;;
    metric-tags)
      jq -e '
        .data.type == "manage_tags"
        and (.data.id | type == "string" and test("\\S"))
        and (.data.attributes | type == "object")
      ' "$payload_file" >/dev/null ||
        die "Metric tag payload requires data.type manage_tags, data.id, and attributes."
      ;;
  esac
}

resource_path() {
  local resource="$1"
  local id="${2:-}"
  case "$resource" in
    dashboard) printf '/api/v1/dashboard%s' "${id:+/$id}" ;;
    monitor) printf '/api/v1/monitor%s' "${id:+/$id}" ;;
    pipeline) printf '/api/v1/logs/config/pipelines%s' "${id:+/$id}" ;;
    metric-metadata) printf '/api/v1/metrics/%s' "$id" ;;
    metric-tags) printf '/api/v2/metrics/%s/tags' "$id" ;;
    *) die "Unsupported resource '$resource'." ;;
  esac
}

get_resource() {
  local resource="$1"
  local id="$2"
  api_request GET "$resource.get" true "$API_BASE$(resource_path "$resource" "$id")"
}

write_plan() {
  local plan_file="$1"
  local plan_json_file="$2"
  [[ ! -L "$plan_file" ]] || die "Plan file '$plan_file' must not be a symbolic link."
  [[ ! -e "$plan_file" ]] || die "Plan file '$plan_file' already exists."
  local parent
  parent=$(dirname "$plan_file")
  [[ -d "$parent" ]] || die "Plan directory '$parent' does not exist."
  local staged
  staged=$(mktemp "$parent/.datadog-plan.XXXXXX")
  chmod 600 "$staged"
  cat "$plan_json_file" >"$staged"
  mv "$staged" "$plan_file"
}

duplicate_count() {
  local resource="$1"
  local name="$2"
  case "$resource" in
    dashboard)
      api_request GET dashboard.duplicate-check true \
        --get "$API_BASE/api/v1/dashboard"
      jq --arg name "$name" '
        [.dashboards[]? | select((.title | ascii_downcase) == ($name | ascii_downcase))] | length
      ' "$RESPONSE_FILE"
      ;;
    monitor)
      api_request GET monitor.duplicate-check true \
        --get --data-urlencode "name=$name" "$API_BASE/api/v1/monitor"
      jq --arg name "$name" '
        [.[]? | select((.name | ascii_downcase) == ($name | ascii_downcase))] | length
      ' "$RESPONSE_FILE"
      ;;
    pipeline)
      api_request GET pipeline.duplicate-check true \
        "$API_BASE/api/v1/logs/config/pipelines"
      jq --arg name "$name" '
        [.[]? | select((.name | ascii_downcase) == ($name | ascii_downcase))] | length
      ' "$RESPONSE_FILE"
      ;;
    *) printf '0\n' ;;
  esac
}

plan_change() {
  local resource="$1"
  local action="$2"
  local id="$3"
  local input_source="$4"
  local plan_file="$5"
  local replace="$6"
  local allow_duplicate="$7"

  local input_file sanitized_input current_file sanitized_current proposed_file plan_json
  read_json_input input_file "$input_source"
  new_temp sanitized_input
  sanitize_resource "$resource" "$input_file" "$sanitized_input"

  local base_hash="null"
  local current_json="null"
  if [[ "$action" == update ]]; then
    get_resource "$resource" "$id"
    current_file="$RESPONSE_FILE"
    new_temp sanitized_current
    sanitize_resource "$resource" "$current_file" "$sanitized_current"
    base_hash="\"$(canonical_hash "$sanitized_current")\""
    new_temp proposed_file
    if [[ "$replace" == true ]]; then
      jq '.' "$sanitized_input" >"$proposed_file"
    else
      jq -s '.[0] * .[1]' "$sanitized_current" "$sanitized_input" >"$proposed_file"
    fi
    current_json=$(jq -c . "$sanitized_current")
  else
    proposed_file="$sanitized_input"
    if [[ "$resource" == dashboard || "$resource" == monitor || "$resource" == pipeline ]]; then
      local name count
      name=$(jq -r 'if has("title") then .title else .name end' "$proposed_file")
      count=$(duplicate_count "$resource" "$name")
      if ((count > 0)) && [[ "$allow_duplicate" != true ]]; then
        die "A $resource named '$name' already exists; use --allow-duplicate only after reviewing the matches."
      fi
    fi
  fi

  validate_payload "$resource" "$proposed_file"
  if [[ "$resource" == metric-tags ]]; then
    local payload_metric
    payload_metric=$(jq -r '.data.id' "$proposed_file")
    [[ "$payload_metric" == "$id" ]] ||
      die "Metric tag payload data.id '$payload_metric' does not match '$id'."
  fi
  if [[ "$resource" == monitor ]]; then
    local validate_path="/api/v1/monitor/validate"
    [[ "$action" != update ]] || validate_path="/api/v1/monitor/$id/validate"
    api_request POST monitor.validate true \
      --header 'Content-Type: application/json' \
      --data-binary "@$proposed_file" \
      "$API_BASE$validate_path"
  fi

  local method path proposed_json changed_fields
  if [[ "$action" == create ]]; then
    method=POST
    if [[ "$resource" == metric-tags ]]; then
      path=$(resource_path "$resource" "$id")
    else
      path=$(resource_path "$resource")
    fi
  else
    case "$resource" in
      metric-tags) method=PATCH ;;
      *) method=PUT ;;
    esac
    path=$(resource_path "$resource" "$id")
  fi
  proposed_json=$(jq -c . "$proposed_file")
  changed_fields=$(jq -cn \
    --argjson before "$current_json" \
    --argjson after "$proposed_json" '
      (($before // {}) + ($after // {}))
      | keys
      | map(select(($before[.] // null) != ($after[.] // null)))
    ')

  new_temp plan_json
  jq -n \
    --argjson version "$PLAN_VERSION" \
    --arg site "$DD_SITE" \
    --arg resource "$resource" \
    --arg action "$action" \
    --arg id "$id" \
    --arg method "$method" \
    --arg path "$path" \
    --argjson payload "$proposed_json" \
    --argjson base_hash "$base_hash" \
    --argjson allow_duplicate "$allow_duplicate" \
    --argjson changed_fields "$changed_fields" '
      {
        version: $version,
        site: $site,
        resource: $resource,
        action: $action,
        id: (if $id == "" then null else $id end),
        method: $method,
        path: $path,
        payload: $payload,
        base_hash: $base_hash,
        allow_duplicate: $allow_duplicate,
        changed_fields: $changed_fields
      }
    ' >"$plan_json"
  seal_plan "$plan_json"
  write_plan "$plan_file" "$plan_json"
  emit_success "$resource.plan-$action" "${id:-new}" "$plan_json" \
    "$(jq -cn --arg plan_file "$plan_file" '{plan_file: $plan_file, requires_apply: true}')"
}

read_plan() {
  local target="$1"
  local plan_file="$2"
  [[ -f "$plan_file" && ! -L "$plan_file" ]] ||
    die "Plan file '$plan_file' is missing or is not a regular file."
  jq -e '
    type == "object"
    and (.version | type == "number")
    and (.site | type == "string")
    and (.resource | type == "string")
    and (.action | type == "string")
    and (.method | type == "string")
    and (.path | type == "string")
    and (.payload | type == "object")
    and (.integrity | type == "string" and test("^[a-f0-9]{64}$"))
  ' "$plan_file" >/dev/null ||
    die "Plan file '$plan_file' is invalid."
  new_temp "$target"
  cat "$plan_file" >"${!target}"
}

apply_plan() {
  local expected_resource="$1"
  local plan_file="$2"
  local apply_flag="$3"
  [[ "$apply_flag" == true ]] ||
    die "Apply requires the literal --apply flag."

  local plan resource action id method path site base_hash payload_file version
  read_plan plan "$plan_file"
  local unsigned_plan expected_integrity actual_integrity
  expected_integrity=$(jq -r '.integrity' "$plan")
  new_temp unsigned_plan
  jq 'del(.integrity)' "$plan" >"$unsigned_plan"
  actual_integrity=$(canonical_hash "$unsigned_plan")
  [[ "$actual_integrity" == "$expected_integrity" ]] ||
    die "Plan integrity check failed; generate and approve a new plan."
  version=$(jq -r '.version' "$plan")
  resource=$(jq -r '.resource' "$plan")
  action=$(jq -r '.action' "$plan")
  id=$(jq -r '.id // ""' "$plan")
  method=$(jq -r '.method' "$plan")
  path=$(jq -r '.path' "$plan")
  site=$(jq -r '.site' "$plan")
  base_hash=$(jq -r '.base_hash // ""' "$plan")
  [[ "$version" == "$PLAN_VERSION" ]] ||
    die "Unsupported plan version '$version'."
  [[ "$resource" == "$expected_resource" ]] ||
    die "Plan resource '$resource' does not match '$expected_resource'."
  [[ "$site" == "$DD_SITE" ]] ||
    die "Plan targets DD_SITE '$site', but the current DD_SITE is '$DD_SITE'."
  if [[ -n "$id" ]]; then
    case "$resource" in
      metric-metadata | metric-tags) validate_metric_name "$id" ;;
      *) validate_id "$resource" "$id" ;;
    esac
  fi

  local expected_method expected_path
  case "$resource:$action" in
    dashboard:create | monitor:create | pipeline:create)
      [[ -z "$id" ]] || die "Create plan must not contain a resource ID."
      expected_method=POST
      expected_path=$(resource_path "$resource")
      ;;
    dashboard:update | monitor:update | pipeline:update | metric-metadata:update)
      [[ -n "$id" ]] || die "Update plan is missing its resource ID."
      expected_method=PUT
      expected_path=$(resource_path "$resource" "$id")
      ;;
    metric-tags:create)
      [[ -n "$id" ]] || die "Metric tag create plan is missing its metric name."
      expected_method=POST
      expected_path=$(resource_path "$resource" "$id")
      ;;
    metric-tags:update)
      [[ -n "$id" ]] || die "Metric tag update plan is missing its metric name."
      expected_method=PATCH
      expected_path=$(resource_path "$resource" "$id")
      ;;
    monitor:mute | monitor:unmute)
      [[ -n "$id" ]] || die "Monitor mute plan is missing its monitor ID."
      expected_method=POST
      expected_path="/api/v1/monitor/$id/$action"
      ;;
    *) die "Unsupported plan action '$resource:$action'." ;;
  esac
  [[ "$method" == "$expected_method" && "$path" == "$expected_path" ]] ||
    die "Plan method or path does not match the supported '$resource:$action' operation."

  new_temp payload_file
  jq '.payload' "$plan" >"$payload_file"
  if [[ "$action" == create || "$action" == update ]]; then
    validate_payload "$resource" "$payload_file"
    if [[ "$resource" == metric-tags ]]; then
      local payload_metric
      payload_metric=$(jq -r '.data.id' "$payload_file")
      [[ "$payload_metric" == "$id" ]] ||
        die "Metric tag payload data.id '$payload_metric' does not match '$id'."
    fi
    if [[ "$resource" == monitor ]]; then
      local validate_path="/api/v1/monitor/validate"
      [[ "$action" != update ]] || validate_path="/api/v1/monitor/$id/validate"
      api_request POST monitor.validate true \
        --header 'Content-Type: application/json' \
        --data-binary "@$payload_file" \
        "$API_BASE$validate_path"
    fi
  else
    jq -e '
      (.scope | type == "string" and test("\\S"))
      and ((has("end") | not) or (.end | type == "number"))
    ' "$payload_file" >/dev/null ||
      die "Monitor mute payload requires a non-empty scope and optional numeric end."
  fi

  if [[ "$action" == update || "$action" == mute || "$action" == unmute ]]; then
    get_resource "$resource" "$id"
    local live_hash
    live_hash=$(resource_hash "$resource" "$RESPONSE_FILE")
    if [[ "$live_hash" != "$base_hash" ]]; then
      emit_error 409 "$resource.apply" concurrency_conflict \
        "The target changed after planning; generate and approve a new plan."
      exit 2
    fi
  elif [[ "$action" == create &&
    ("$resource" == dashboard || "$resource" == monitor || "$resource" == pipeline) ]]; then
    local name count allow_duplicate
    name=$(jq -r '.payload | if has("title") then .title else .name end' "$plan")
    allow_duplicate=$(jq -r '.allow_duplicate' "$plan")
    count=$(duplicate_count "$resource" "$name")
    if ((count > 0)) && [[ "$allow_duplicate" != true ]]; then
      die "A $resource named '$name' appeared after planning; generate a new plan."
    fi
  fi

  local -a request_args
  request_args=(--header 'Content-Type: application/json')
  if [[ "$action" != unmute ]]; then
    request_args+=(--data-binary "@$payload_file")
  elif [[ "$(jq '.payload | length' "$plan")" != 0 ]]; then
    request_args+=(--data-binary "@$payload_file")
  fi
  api_request "$method" "$resource.apply" false \
    "${request_args[@]}" "$API_BASE$path"
  rm -f "$plan_file"
  emit_success "$resource.apply" "${id:-new}" "$RESPONSE_FILE" \
    '{"plan_invalidated":true}'
}

dashboard_list() {
  local name="" limit=$DEFAULT_LIST_LIMIT page=0 raw=false
  while (($#)); do
    case "$1" in
      --name) (($# >= 2)) || usage; name="$2"; shift 2 ;;
      --limit) (($# >= 2)) || usage; limit="$2"; shift 2 ;;
      --page) (($# >= 2)) || usage; page="$2"; shift 2 ;;
      --raw) raw=true; shift ;;
      *) usage ;;
    esac
  done
  validate_limit "$limit" "$MAX_LIST_LIMIT"
  validate_offset "$page"
  local start=$((page * limit))
  api_request GET dashboard.list true --get "$API_BASE/api/v1/dashboard"
  local filtered
  new_temp filtered
  jq \
    --arg name "$name" \
    --argjson start "$start" \
    --argjson limit "$limit" '
      (.dashboards // [])
      | map(select($name == "" or ((.title // "") | ascii_downcase | contains($name | ascii_downcase))))
      | {
          items: .[$start:$start + $limit],
          total: length,
          next_page: (if length > ($start + $limit) then (($start / $limit) + 1) else null end)
        }
    ' "$RESPONSE_FILE" >"$filtered"
  RESPONSE_FILE="$filtered"
  emit_read dashboard.list dashboards "$raw" \
    "$(jq -cn --argjson limit "$limit" --argjson page "$page" '{limit:$limit,page:$page}')"
}

monitor_list() {
  local query="" limit=$DEFAULT_LIST_LIMIT page=0 raw=false
  while (($#)); do
    case "$1" in
      --query) (($# >= 2)) || usage; query="$2"; shift 2 ;;
      --limit) (($# >= 2)) || usage; limit="$2"; shift 2 ;;
      --page) (($# >= 2)) || usage; page="$2"; shift 2 ;;
      --raw) raw=true; shift ;;
      *) usage ;;
    esac
  done
  validate_limit "$limit" "$MAX_LIST_LIMIT"
  validate_offset "$page"
  api_request GET monitor.list true \
    --get \
    --data-urlencode "query=$query" \
    --data-urlencode "page=$page" \
    --data-urlencode "per_page=$limit" \
    "$API_BASE/api/v1/monitor/search"
  emit_read monitor.list monitors "$raw" \
    "$(jq -cn --arg query "$query" --argjson limit "$limit" --argjson page "$page" \
      '{query:$query,limit:$limit,page:$page}')"
}

pipeline_list() {
  local name="" limit=$DEFAULT_LIST_LIMIT offset=0 raw=false
  while (($#)); do
    case "$1" in
      --name) (($# >= 2)) || usage; name="$2"; shift 2 ;;
      --limit) (($# >= 2)) || usage; limit="$2"; shift 2 ;;
      --offset) (($# >= 2)) || usage; offset="$2"; shift 2 ;;
      --raw) raw=true; shift ;;
      *) usage ;;
    esac
  done
  validate_limit "$limit" "$MAX_LIST_LIMIT"
  validate_offset "$offset"
  api_request GET pipeline.list true "$API_BASE/api/v1/logs/config/pipelines"
  local filtered
  new_temp filtered
  jq \
    --arg name "$name" \
    --argjson offset "$offset" \
    --argjson limit "$limit" '
      map(select($name == "" or ((.name // "") | ascii_downcase | contains($name | ascii_downcase))))
      | {
          items: .[$offset:$offset + $limit],
          total: length,
          next_offset: (if length > ($offset + $limit) then ($offset + $limit) else null end)
        }
    ' "$RESPONSE_FILE" >"$filtered"
  RESPONSE_FILE="$filtered"
  emit_read pipeline.list pipelines "$raw" \
    "$(jq -cn --argjson limit "$limit" --argjson offset "$offset" \
      '{limit:$limit,offset:$offset}')"
}

resource_get() {
  local resource="$1"
  local id="$2"
  local raw="$3"
  validate_id "$resource" "$id"
  get_resource "$resource" "$id"
  emit_read "$resource.get" "$id" "$raw"
}

resource_export() {
  local resource="$1"
  local id="$2"
  validate_id "$resource" "$id"
  get_resource "$resource" "$id"
  local exported
  new_temp exported
  sanitize_resource "$resource" "$RESPONSE_FILE" "$exported"
  cat "$exported"
  printf '\n'
}

plan_mute() {
  local action="$1"
  local id="$2"
  shift 2
  validate_id monitor "$id"
  local scope="" end="" indefinite=false plan_file=""
  while (($#)); do
    case "$1" in
      --scope) (($# >= 2)) || usage; scope="$2"; shift 2 ;;
      --end) (($# >= 2)) || usage; end="$2"; shift 2 ;;
      --indefinite) indefinite=true; shift ;;
      --plan-file) (($# >= 2)) || usage; plan_file="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "$scope" && -n "$plan_file" ]] || usage
  if [[ "$action" == mute ]]; then
    if [[ "$indefinite" == true ]]; then
      [[ -z "$end" ]] || die "Use either --end or --indefinite, not both."
    else
      [[ -n "$end" ]] || usage
      validate_iso_utc end "$end"
      [[ "$end" != *.* ]] ||
        die "Monitor mute end must use whole-second UTC precision."
    fi
  elif [[ -n "$end" || "$indefinite" == true ]]; then
    usage
  fi

  get_resource monitor "$id"
  local base_hash payload plan_json path
  base_hash=$(resource_hash monitor "$RESPONSE_FILE")
  new_temp payload
  if [[ "$action" == mute ]]; then
    if [[ "$indefinite" == true ]]; then
      jq -n --arg scope "$scope" '{scope:$scope}' >"$payload"
    else
      local end_epoch
      if end_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$end" '+%s' 2>/dev/null); then
        :
      else
        end_epoch=$(date -u -d "$end" '+%s')
      fi
      jq -n --arg scope "$scope" --argjson end "$end_epoch" \
        '{scope:$scope,end:$end}' >"$payload"
    fi
  else
    jq -n --arg scope "$scope" '{scope:$scope}' >"$payload"
  fi
  path="/api/v1/monitor/$id/$action"
  new_temp plan_json
  jq -n \
    --argjson version "$PLAN_VERSION" \
    --arg site "$DD_SITE" \
    --arg action "$action" \
    --arg id "$id" \
    --arg path "$path" \
    --slurpfile payload "$payload" \
    --arg base_hash "$base_hash" '
      {
        version:$version,
        site:$site,
        resource:"monitor",
        action:$action,
        id:$id,
        method:"POST",
        path:$path,
        payload:$payload[0],
        base_hash:$base_hash,
        allow_duplicate:false,
        changed_fields:["muted"]
      }
    ' >"$plan_json"
  seal_plan "$plan_json"
  write_plan "$plan_file" "$plan_json"
  emit_success "monitor.plan-$action" "$id" "$plan_json" \
    "$(jq -cn --arg plan_file "$plan_file" '{plan_file:$plan_file,requires_apply:true}')"
}

metrics_query() {
  local kind="$1"
  shift
  local input="" raw=false
  while (($#)); do
    case "$1" in
      --input) (($# >= 2)) || usage; input="$2"; shift 2 ;;
      --raw) raw=true; shift ;;
      *) usage ;;
    esac
  done
  [[ -n "$input" ]] || usage
  local payload
  read_json_input payload "$input"
  api_request POST "metrics.$kind" true \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload" \
    "$API_BASE/api/v2/query/$kind"
  emit_read "metrics.$kind" metrics "$raw"
}

logs_search() {
  local query="" from="" to="" limit=$DEFAULT_LOG_LIMIT cursor="" raw=false
  while (($#)); do
    case "$1" in
      --query) (($# >= 2)) || usage; query="$2"; shift 2 ;;
      --from) (($# >= 2)) || usage; from="$2"; shift 2 ;;
      --to) (($# >= 2)) || usage; to="$2"; shift 2 ;;
      --limit) (($# >= 2)) || usage; limit="$2"; shift 2 ;;
      --cursor) (($# >= 2)) || usage; cursor="$2"; shift 2 ;;
      --raw) raw=true; shift ;;
      *) usage ;;
    esac
  done
  [[ -n "$query" ]] || usage
  [[ -n "$from" ]] || from=$(utc_24_hours_ago)
  [[ -n "$to" ]] || to=$(utc_now)
  validate_iso_utc from "$from"
  validate_iso_utc to "$to"
  validate_limit "$limit" "$MAX_LOG_LIMIT"

  local payload
  new_temp payload
  jq -n \
    --arg query "$query" \
    --arg from "$from" \
    --arg to "$to" \
    --arg cursor "$cursor" \
    --argjson limit "$limit" '
      {
        filter:{query:$query,from:$from,to:$to},
        sort:"timestamp",
        page:{limit:$limit}
      }
      | if $cursor == "" then . else .page.cursor = $cursor end
    ' >"$payload"
  api_request POST logs.search true \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload" \
    "$API_BASE/api/v2/logs/events/search"
  emit_read logs.search logs "$raw" \
    "$(jq -cn --arg query "$query" --arg from "$from" --arg to "$to" \
      --argjson limit "$limit" '{query:$query,from:$from,to:$to,limit:$limit}')"
}

logs_aggregate() {
  local input="" raw=false
  while (($#)); do
    case "$1" in
      --input) (($# >= 2)) || usage; input="$2"; shift 2 ;;
      --raw) raw=true; shift ;;
      *) usage ;;
    esac
  done
  [[ -n "$input" ]] || usage
  local source payload from to
  read_json_input source "$input"
  from=$(utc_24_hours_ago)
  to=$(utc_now)
  new_temp payload
  jq --arg from "$from" --arg to "$to" '
    .filter = (
      (.filter // {})
      | .from = (.from // $from)
      | .to = (.to // $to)
    )
  ' "$source" >"$payload"
  from=$(jq -r '.filter.from' "$payload")
  to=$(jq -r '.filter.to' "$payload")
  validate_iso_utc from "$from"
  validate_iso_utc to "$to"
  api_request POST logs.aggregate true \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload" \
    "$API_BASE/api/v2/logs/analytics/aggregate"
  emit_read logs.aggregate logs "$raw"
}

parse_plan_args() {
  local mode="$1"
  local resource="$2"
  local id="$3"
  shift 3
  local input="" plan_file="" replace=false allow_duplicate=false
  while (($#)); do
    case "$1" in
      --input) (($# >= 2)) || usage; input="$2"; shift 2 ;;
      --plan-file) (($# >= 2)) || usage; plan_file="$2"; shift 2 ;;
      --replace) replace=true; shift ;;
      --allow-duplicate) allow_duplicate=true; shift ;;
      *) usage ;;
    esac
  done
  [[ -n "$input" && -n "$plan_file" ]] || usage
  [[ "$mode" == update || "$replace" == false ]] || usage
  [[ "$mode" == create || "$allow_duplicate" == false ]] || usage
  [[ -z "$id" ]] || validate_id "$resource" "$id"
  plan_change "$resource" "$mode" "$id" "$input" "$plan_file" \
    "$replace" "$allow_duplicate"
}

handle_resource() {
  local resource="$1"
  shift
  (($# > 0)) || usage
  local command="$1"
  shift
  case "$command" in
    list)
      case "$resource" in
        dashboard) dashboard_list "$@" ;;
        monitor) monitor_list "$@" ;;
        pipeline) pipeline_list "$@" ;;
      esac
      ;;
    get)
      (($# >= 1 && $# <= 2)) || usage
      local raw=false
      if (($# == 2)); then
        [[ "$2" == --raw ]] || usage
        raw=true
      fi
      resource_get "$resource" "$1" "$raw"
      ;;
    export) (($# == 1)) || usage; resource_export "$resource" "$1" ;;
    plan-create) parse_plan_args create "$resource" "" "$@" ;;
    plan-update)
      (($# >= 1)) || usage
      local id="$1"
      shift
      parse_plan_args update "$resource" "$id" "$@"
      ;;
    plan-mute | plan-unmute)
      [[ "$resource" == monitor ]] && (($# >= 1)) || usage
      local action="${command#plan-}"
      local id="$1"
      shift
      plan_mute "$action" "$id" "$@"
      ;;
    apply)
      (($# == 2)) && [[ "$2" == --apply ]] || usage
      apply_plan "$resource" "$1" true
      ;;
    *) usage ;;
  esac
}

handle_metric_config() {
  local resource="$1"
  shift
  (($# > 0)) || usage
  local command="$1"
  shift
  case "$command" in
    get)
      (($# >= 1 && $# <= 2)) || usage
      validate_metric_name "$1"
      local raw=false
      if (($# == 2)); then
        [[ "$2" == --raw ]] || usage
        raw=true
      fi
      get_resource "$resource" "$1"
      emit_read "$resource.get" "$1" "$raw"
      ;;
    export)
      (($# == 1)) || usage
      validate_metric_name "$1"
      resource_export "$resource" "$1"
      ;;
    plan-create)
      [[ "$resource" == metric-tags ]] && (($# >= 1)) || usage
      local name="$1"
      shift
      validate_metric_name "$name"
      parse_plan_args create "$resource" "$name" "$@"
      ;;
    plan-update)
      (($# >= 1)) || usage
      local name="$1"
      shift
      validate_metric_name "$name"
      parse_plan_args update "$resource" "$name" "$@"
      ;;
    apply)
      (($# == 2)) && [[ "$2" == --apply ]] || usage
      apply_plan "$resource" "$1" true
      ;;
    *) usage ;;
  esac
}

main() {
  (($# > 0)) || usage
  configure
  verify_auth

  local command="$1"
  shift
  case "$command" in
    verify)
      (($# == 0)) || usage
      emit_success verify "$DD_SITE" "$VERIFY_FILE" \
        "$(jq -cn \
          --arg site "$DD_SITE" \
          --arg api_base "$API_BASE" \
          --arg auth_mode "$AUTH_MODE" \
          --arg token_id "$TOKEN_ID" '
            {
              site:$site,
              api_base:$api_base,
              auth_mode:$auth_mode
            }
            + if $token_id == "" then {} else {token_id:$token_id} end
          ')"
      ;;
    dashboard | monitor | pipeline) handle_resource "$command" "$@" ;;
    metrics)
      (($# > 0)) || usage
      local branch="$1"
      shift
      case "$branch" in
        timeseries | scalar) metrics_query "$branch" "$@" ;;
        metadata) handle_metric_config metric-metadata "$@" ;;
        tags) handle_metric_config metric-tags "$@" ;;
        *) usage ;;
      esac
      ;;
    logs)
      (($# > 0)) || usage
      local branch="$1"
      shift
      case "$branch" in
        search) logs_search "$@" ;;
        aggregate) logs_aggregate "$@" ;;
        *) usage ;;
      esac
      ;;
    *) usage ;;
  esac
}

main "$@"
