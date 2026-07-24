#!/usr/bin/env bash
set -euo pipefail

readonly BASE_URL="https://api.figma.com/v1"
TEMP_FILES=()
AUTH_CONFIG=""
RESPONSE_FILE=""
RESOLVED_FILE_KEY=""
RESOLVED_NODE_ID=""

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
  figma.sh verify
  figma.sh read-file {URL|FILE_KEY} [--depth DEPTH]
  figma.sh read-nodes {URL|FILE_KEY} [NODE_IDS] [--depth DEPTH]
  figma.sh read-comments {URL|FILE_KEY}
  figma.sh add-comment {URL|FILE_KEY} [--node NODE_ID --offset-x X --offset-y Y] < comment.md
  figma.sh reply-comment {URL|FILE_KEY} COMMENT_ID < comment.md
EOF
  exit 2
}

die() {
  echo "$1" >&2
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

configure() {
  if [[ -z "${FIGMA_TOKEN:-}" ]]; then
    echo "Missing environment variable: FIGMA_TOKEN." >&2
    exit 1
  fi
  if [[ "$FIGMA_TOKEN" == *$'\n'* || "$FIGMA_TOKEN" == *$'\r'* ]]; then
    echo "FIGMA_TOKEN contains a newline or carriage return." >&2
    exit 1
  fi
  command -v curl >/dev/null || {
    echo "Required command not found: curl." >&2
    exit 1
  }
  command -v jq >/dev/null || {
    echo "Required command not found: jq." >&2
    exit 1
  }

  new_temp AUTH_CONFIG
  local escaped_token="${FIGMA_TOKEN//\\/\\\\}"
  escaped_token="${escaped_token//\"/\\\"}"
  printf 'header = "X-Figma-Token: %s"\n' "$escaped_token" >"$AUTH_CONFIG"
  unset FIGMA_TOKEN
}

http_failure() {
  local operation="$1"
  local resource="$2"
  local http_code="$3"
  local response_file="$4"
  local headers_file="$5"
  local diagnostic=""
  local retry_after=""

  if [[ -s "$response_file" ]] && jq -e . "$response_file" >/dev/null 2>&1; then
    diagnostic=$(jq -r '
      if type == "object" then
        (.err // .message // .error // empty | tostring | gsub("\\n"; " "))
      else
        empty
      end
    ' "$response_file")
  fi

  case "$http_code" in
    400) echo "Invalid request while $operation $resource (HTTP 400)." >&2 ;;
    401) echo "Authentication failed while $operation $resource (HTTP 401)." >&2 ;;
    403) echo "Authentication or permission failed while $operation $resource (HTTP 403)." >&2 ;;
    404) echo "$resource was not found or is not visible while $operation (HTTP 404)." >&2 ;;
    429)
      echo "Figma rate limited the request while $operation $resource (HTTP 429)." >&2
      retry_after=$(awk '
        tolower($1) == "retry-after:" { value = $2 }
        END { gsub("\r", "", value); print value }
      ' "$headers_file")
      [[ -z "$retry_after" ]] || echo "Retry-After: ${retry_after}s." >&2
      ;;
    5??) echo "Figma failed while $operation $resource (HTTP $http_code)." >&2 ;;
    *) echo "Unexpected response while $operation $resource (HTTP $http_code)." >&2 ;;
  esac
  [[ -z "$diagnostic" ]] || echo "Figma: $diagnostic" >&2
  exit 3
}

api_request() {
  local method="$1"
  local operation="$2"
  local resource="$3"
  shift 3

  local headers_file http_code curl_status
  new_temp RESPONSE_FILE
  new_temp headers_file

  if http_code=$(curl \
    --silent \
    --show-error \
    --output "$RESPONSE_FILE" \
    --dump-header "$headers_file" \
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
    echo "Transport failure while $operation $resource (curl exit $curl_status)." >&2
    exit 3
  fi
  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    http_failure "$operation" "$resource" "$http_code" "$RESPONSE_FILE" "$headers_file"
  fi
  if ! jq -e . "$RESPONSE_FILE" >/dev/null 2>&1; then
    echo "Figma returned a non-JSON success response while $operation $resource (HTTP $http_code)." >&2
    exit 3
  fi
}

emit_response() {
  cat "$RESPONSE_FILE"
  printf '\n'
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_node_ids() {
  local input="$1"
  [[ -n "$input" ]] || die "Node IDs are empty."

  local -a parts normalized_parts
  local part normalized joined=""
  IFS=',' read -r -a parts <<<"$input"
  ((${#parts[@]} > 0)) || die "Node IDs are empty."

  for part in "${parts[@]}"; do
    part=$(trim "$part")
    part="${part//%3A/:}"
    part="${part//%3a/:}"
    part="${part//%2D/-}"
    part="${part//%2d/-}"
    part="${part//%3B/;}"
    part="${part//%3b/;}"
    normalized="${part//-/:}"
    if [[ ! "$normalized" =~ ^I?[0-9]+:[0-9]+(\;[0-9]+:[0-9]+)*$ ]]; then
      die "Invalid node ID '$part'; expected an ID such as 12:34."
    fi
    normalized_parts+=("$normalized")
  done

  for normalized in "${normalized_parts[@]}"; do
    [[ -z "$joined" ]] || joined+=","
    joined+="$normalized"
  done
  printf '%s\n' "$joined"
}

validate_file_key() {
  local file_key="$1"
  if [[ ! "$file_key" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die "Invalid Figma file key '$file_key'."
  fi
}

resolve_resource() {
  local reference="$1"
  local remainder host path file_type file_key query pair key value
  local node_parameter_count=0
  local -a query_parts

  RESOLVED_FILE_KEY=""
  RESOLVED_NODE_ID=""

  if [[ "$reference" == https://* ]]; then
    remainder="${reference#https://}"
    [[ "$remainder" == */* ]] || die "Invalid Figma URL '$reference'."
    host="${remainder%%/*}"
    if [[ "$host" != "figma.com" && "$host" != "www.figma.com" ]]; then
      die "Invalid Figma host '$host'; expected www.figma.com."
    fi

    remainder="${remainder#*/}"
    path="${remainder%%\?*}"
    path="${path%%\#*}"
    IFS='/' read -r file_type file_key _ <<<"$path"
    case "$file_type" in
      design | file | proto | board) ;;
      *) die "Unsupported Figma URL type '$file_type'." ;;
    esac
    [[ -n "$file_key" ]] || die "Figma URL does not contain a file key."
    validate_file_key "$file_key"
    RESOLVED_FILE_KEY="$file_key"

    if [[ "$reference" == *\?* ]]; then
      query="${reference#*\?}"
      query="${query%%\#*}"
      if [[ -n "$query" ]]; then
        IFS='&' read -r -a query_parts <<<"$query"
        for pair in "${query_parts[@]}"; do
          key="${pair%%=*}"
          [[ "$key" == "node-id" ]] || continue
          [[ "$pair" == *=* ]] || die "Figma URL has an empty node-id parameter."
          value="${pair#*=}"
          [[ -n "$value" ]] || die "Figma URL has an empty node-id parameter."
          ((node_parameter_count += 1))
          ((node_parameter_count == 1)) || die "Figma URL contains more than one node-id parameter."
          RESOLVED_NODE_ID=$(normalize_node_ids "$value")
        done
      fi
    fi
    return
  fi

  if [[ "$reference" == *"://"* ]]; then
    die "Invalid Figma resource '$reference'; expected an HTTPS Figma URL or file key."
  fi
  validate_file_key "$reference"
  RESOLVED_FILE_KEY="$reference"
}

validate_depth() {
  local depth="$1"
  [[ "$depth" =~ ^[1-9][0-9]*$ ]] || die "Invalid depth '$depth'; expected a positive integer."
}

validate_coordinate() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]] ||
    die "Invalid $name '$value'; expected an integer or decimal number."
}

read_message() {
  local target="$1"
  new_temp "$target"
  cat >"${!target}"
  if [[ ! -s "${!target}" ]] || ! grep -q '[^[:space:]]' "${!target}"; then
    die "Comment text is empty; provide it on standard input."
  fi
}

verify() {
  (($# == 0)) || usage
  api_request GET "verifying" "the current user" "$BASE_URL/me"
  if ! jq -e '
    type == "object"
    and (.id | type == "string")
    and (.handle | type == "string")
  ' "$RESPONSE_FILE" >/dev/null; then
    echo "Figma returned an invalid current-user response." >&2
    exit 3
  fi
  jq '{id, handle}' "$RESPONSE_FILE"
}

read_file() {
  (($# >= 1)) || usage
  local resource="$1"
  shift
  local depth=2

  while (($#)); do
    case "$1" in
      --depth)
        (($# >= 2)) || usage
        depth="$2"
        shift 2
        ;;
      *) usage ;;
    esac
  done

  validate_depth "$depth"
  resolve_resource "$resource"
  api_request GET "reading" "file $RESOLVED_FILE_KEY" \
    --get \
    --data-urlencode "depth=$depth" \
    "$BASE_URL/files/$RESOLVED_FILE_KEY"
  emit_response
}

read_nodes() {
  (($# >= 1)) || usage
  local resource="$1"
  shift
  local explicit_ids=""
  local depth=""

  while (($#)); do
    case "$1" in
      --depth)
        (($# >= 2)) || usage
        depth="$2"
        shift 2
        ;;
      --*) usage ;;
      *)
        [[ -z "$explicit_ids" ]] || usage
        explicit_ids="$1"
        shift
        ;;
    esac
  done

  [[ -z "$depth" ]] || validate_depth "$depth"
  resolve_resource "$resource"
  if [[ -n "$explicit_ids" && -n "$RESOLVED_NODE_ID" ]]; then
    die "The Figma URL already contains node-id; omit NODE_IDS or use a file key."
  fi

  local node_ids
  if [[ -n "$explicit_ids" ]]; then
    node_ids=$(normalize_node_ids "$explicit_ids")
  elif [[ -n "$RESOLVED_NODE_ID" ]]; then
    node_ids="$RESOLVED_NODE_ID"
  else
    die "Node IDs are required when the Figma URL has no node-id parameter."
  fi

  if [[ -n "$depth" ]]; then
    api_request GET "reading nodes from" "file $RESOLVED_FILE_KEY" \
      --get \
      --data-urlencode "ids=$node_ids" \
      --data-urlencode "depth=$depth" \
      "$BASE_URL/files/$RESOLVED_FILE_KEY/nodes"
  else
    api_request GET "reading nodes from" "file $RESOLVED_FILE_KEY" \
      --get \
      --data-urlencode "ids=$node_ids" \
      "$BASE_URL/files/$RESOLVED_FILE_KEY/nodes"
  fi
  emit_response
}

read_comments() {
  (($# == 1)) || usage
  resolve_resource "$1"
  api_request GET "reading comments from" "file $RESOLVED_FILE_KEY" \
    --get \
    --data-urlencode 'as_md=true' \
    "$BASE_URL/files/$RESOLVED_FILE_KEY/comments"
  emit_response
}

add_comment() {
  (($# >= 1)) || usage
  local resource="$1"
  shift
  local node_id=""
  local offset_x=""
  local offset_y=""

  while (($#)); do
    case "$1" in
      --node)
        (($# >= 2)) || usage
        node_id="$2"
        shift 2
        ;;
      --offset-x)
        (($# >= 2)) || usage
        offset_x="$2"
        shift 2
        ;;
      --offset-y)
        (($# >= 2)) || usage
        offset_y="$2"
        shift 2
        ;;
      *) usage ;;
    esac
  done

  resolve_resource "$resource"
  if [[ -n "$node_id" ]]; then
    node_id=$(normalize_node_ids "$node_id")
    [[ "$node_id" != *,* ]] || die "An anchored comment accepts exactly one node ID."
  fi
  if [[ -n "$RESOLVED_NODE_ID" ]]; then
    if [[ -n "$node_id" && "$node_id" != "$RESOLVED_NODE_ID" ]]; then
      die "The explicit node ID does not match the Figma URL node-id."
    fi
    node_id="$RESOLVED_NODE_ID"
  fi

  if [[ -n "$node_id" ]]; then
    [[ -n "$offset_x" && -n "$offset_y" ]] ||
      die "Anchored comments require --offset-x and --offset-y."
    validate_coordinate "offset x" "$offset_x"
    validate_coordinate "offset y" "$offset_y"
  elif [[ -n "$offset_x" || -n "$offset_y" ]]; then
    die "Comment offsets require --node or a Figma URL with node-id."
  fi

  local message_file payload_file
  read_message message_file
  new_temp payload_file
  if [[ -n "$node_id" ]]; then
    jq -n \
      --rawfile message "$message_file" \
      --arg node_id "$node_id" \
      --argjson x "$offset_x" \
      --argjson y "$offset_y" \
      '{
        message: $message,
        client_meta: {
          node_id: $node_id,
          node_offset: {x: $x, y: $y}
        }
      }' >"$payload_file"
  else
    jq -n --rawfile message "$message_file" '{message: $message}' >"$payload_file"
  fi

  api_request POST "adding a comment to" "file $RESOLVED_FILE_KEY" \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload_file" \
    "$BASE_URL/files/$RESOLVED_FILE_KEY/comments"
  emit_response
}

reply_comment() {
  (($# == 2)) || usage
  local resource="$1"
  local comment_id="$2"
  [[ "$comment_id" =~ ^[A-Za-z0-9:_-]+$ ]] ||
    die "Invalid comment ID '$comment_id'."

  resolve_resource "$resource"
  local message_file payload_file comments_file target_count root_id root_count root_parent
  read_message message_file

  api_request GET "resolving reply target in" "file $RESOLVED_FILE_KEY" \
    --get \
    --data-urlencode 'as_md=true' \
    "$BASE_URL/files/$RESOLVED_FILE_KEY/comments"
  comments_file="$RESPONSE_FILE"

  target_count=$(jq --arg id "$comment_id" '
    [.comments[]? | select(.id == $id)] | length
  ' "$comments_file")
  [[ "$target_count" == 1 ]] ||
    die "Comment '$comment_id' was not found uniquely in file $RESOLVED_FILE_KEY."

  root_id=$(jq -r --arg id "$comment_id" '
    .comments[]
    | select(.id == $id)
    | (.parent_id // .id)
  ' "$comments_file")
  root_count=$(jq --arg id "$root_id" '
    [.comments[]? | select(.id == $id)] | length
  ' "$comments_file")
  [[ "$root_count" == 1 ]] ||
    die "Root comment '$root_id' was not found uniquely in file $RESOLVED_FILE_KEY."
  root_parent=$(jq -r --arg id "$root_id" '
    .comments[]
    | select(.id == $id)
    | (.parent_id // "")
  ' "$comments_file")
  [[ -z "$root_parent" ]] ||
    die "Resolved comment '$root_id' is not a root comment."

  new_temp payload_file
  jq -n \
    --rawfile message "$message_file" \
    --arg comment_id "$root_id" \
    '{message: $message, comment_id: $comment_id}' >"$payload_file"

  api_request POST "replying to comment $root_id in" "file $RESOLVED_FILE_KEY" \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload_file" \
    "$BASE_URL/files/$RESOLVED_FILE_KEY/comments"
  emit_response
}

(($# > 0)) || usage
command="$1"
shift

case "$command" in
  verify | read-file | read-nodes | read-comments | add-comment | reply-comment)
    configure
    ;;
  *) usage ;;
esac

case "$command" in
  verify) verify "$@" ;;
  read-file) read_file "$@" ;;
  read-nodes) read_nodes "$@" ;;
  read-comments) read_comments "$@" ;;
  add-comment) add_comment "$@" ;;
  reply-comment) reply_comment "$@" ;;
esac
