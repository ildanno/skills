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
  youtrack.sh move {PROJECT-NUMBER|NUMBER} COLUMN
  youtrack.sh assign {PROJECT-NUMBER|NUMBER} LOGIN
  youtrack.sh create --summary SUMMARY [--project PROJECT] < description.md
  youtrack.sh link {PROJECT-NUMBER|NUMBER} {depends-on|required-for|parent-for|subtask-of} {PROJECT-NUMBER|NUMBER}
EOF
  exit 2
}

fail_http() {
  local operation="$1"
  local resource="$2"
  local http_code="$3"
  local response_file="${4:-}"
  local diagnostic=""

  if [[ -n "$response_file" && -s "$response_file" ]]; then
    diagnostic=$(jq -r '
      if type == "object" then
        (.error_description // .error // .message // empty | tostring | gsub("\\n"; " "))
      else
        empty
      end
    ' "$response_file" 2>/dev/null || true)
  fi

  case "$http_code" in
    400) echo "Invalid request while $operation $resource (HTTP 400)." >&2 ;;
    401) echo "Authentication failed while $operation $resource (HTTP 401)." >&2 ;;
    403) echo "Permission denied while $operation $resource (HTTP 403)." >&2 ;;
    404) echo "$resource was not found or is not visible while $operation (HTTP 404)." >&2 ;;
    *) echo "YouTrack failed while $operation $resource (HTTP $http_code)." >&2 ;;
  esac
  [[ -z "$diagnostic" ]] || echo "YouTrack: $diagnostic" >&2
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

resolve_project_id() {
  local project_reference="$1"
  local projects_file http_code project_id
  projects_file=$(mktemp)
  TEMP_FILES+=("$projects_file")

  http_code=$(curl --silent --show-error --output "$projects_file" --write-out '%{http_code}' \
    --get \
    --header "Authorization: Bearer $YOUTRACK_TOKEN" \
    --header 'Accept: application/json' \
    --data-urlencode 'fields=id,name,shortName' \
    --data-urlencode "query=$project_reference" \
    "$BASE_URL/admin/projects")
  [[ "$http_code" == 200 ]] || fail_http "resolving project" "$project_reference" "$http_code" "$projects_file"

  project_id=$(jq -r --arg reference "$project_reference" '
    ($reference | ascii_downcase) as $normalized_reference
    | [
        .[]
        | select(
            ((.shortName // "") | ascii_downcase) == $normalized_reference
            or ((.name // "") | ascii_downcase) == $normalized_reference
          )
      ]
    | if length == 1 then .[0].id else empty end
  ' "$projects_file")
  if [[ -z "$project_id" ]]; then
    echo "Project '$project_reference' was not found uniquely; use its exact short name." >&2
    exit 2
  fi
  printf '%s\n' "$project_id"
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
  [[ "$http_code" == 200 ]] || fail_http "reading" "issue $issue_id" "$http_code" "$issue_file"

  if ((include_comments)); then
    http_code=$(curl --silent --show-error --output "$comments_file" --write-out '%{http_code}' \
      --header "Authorization: Bearer $YOUTRACK_TOKEN" \
      --header 'Accept: application/json' \
      "$BASE_URL/issues/$issue_id/comments?fields=$COMMENT_FIELDS")
    [[ "$http_code" == 200 ]] || fail_http "reading comments for" "issue $issue_id" "$http_code" "$comments_file"
  else
    printf '[]' >"$comments_file"
  fi

  jq --arg include_comments "$include_comments" --slurpfile comments "$comments_file" '
    {
      issue: .,
      commentsIncluded: ($include_comments == "1"),
      comments: $comments[0]
    }
  ' "$issue_file"
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

  jq -n --rawfile text "$comment_file" '{text: $text}' >"$payload_file"

  http_code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --request POST \
    --header "Authorization: Bearer $YOUTRACK_TOKEN" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload_file" \
    "$BASE_URL/issues/$issue_id/comments?fields=$COMMENT_FIELDS")
  [[ "$http_code" == 200 ]] || fail_http "commenting on" "issue $issue_id" "$http_code" "$response_file"
  cat "$response_file"
  printf '\n'
}

apply_command() {
  local issue_id="$1"
  local query="$2"
  local operation="$3"
  local payload_file response_file http_code
  payload_file=$(mktemp)
  response_file=$(mktemp)
  TEMP_FILES+=("$payload_file" "$response_file")

  jq -n --arg issue_id "$issue_id" --arg query "$query" '
    {query: $query, issues: [{idReadable: $issue_id}]}
  ' >"$payload_file"

  http_code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --request POST \
    --header "Authorization: Bearer $YOUTRACK_TOKEN" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload_file" \
    "$BASE_URL/commands?fields=query,issues(id,idReadable,summary)")
  [[ "$http_code" == 200 ]] || fail_http "$operation" "issue $issue_id" "$http_code" "$response_file"
  cat "$response_file"
  printf '\n'
}

move_issue() {
  local issue_id="$1"
  local column="$2"
  local column_field="${YOUTRACK_COLUMN_FIELD:-State}"

  [[ "$column" =~ [^[:space:]] ]] || usage
  apply_command "$issue_id" "$column_field $column" "moving"
}

assign_issue() {
  local issue_id="$1"
  local assignee="$2"

  if [[ ! "$assignee" =~ ^[^[:space:]]+$ ]]; then
    echo "Invalid assignee '$assignee'; use a YouTrack login without spaces." >&2
    exit 2
  fi
  apply_command "$issue_id" "for $assignee" "assigning"
}

create_issue() {
  local summary=""
  local project_reference="${YOUTRACK_PROJECT:-}"

  while (($#)); do
    case "$1" in
      --summary)
        (($# >= 2)) || usage
        summary="$2"
        shift 2
        ;;
      --project)
        (($# >= 2)) || usage
        project_reference="$2"
        shift 2
        ;;
      *) usage ;;
    esac
  done

  [[ "$summary" =~ [^[:space:]] ]] || usage
  if [[ -z "$project_reference" ]]; then
    echo "YOUTRACK_PROJECT is missing; provide --project when creating an issue." >&2
    exit 1
  fi

  local description_file payload_file response_file project_id http_code
  description_file=$(mktemp)
  payload_file=$(mktemp)
  response_file=$(mktemp)
  TEMP_FILES+=("$description_file" "$payload_file" "$response_file")
  cat >"$description_file"
  project_id=$(resolve_project_id "$project_reference")

  jq -n \
    --arg project_id "$project_id" \
    --arg summary "$summary" \
    --rawfile description "$description_file" '
      {project: {id: $project_id}, summary: $summary}
      + if ($description | test("\\S")) then {description: $description} else {} end
    ' >"$payload_file"

  http_code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --request POST \
    --header "Authorization: Bearer $YOUTRACK_TOKEN" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload_file" \
    "$BASE_URL/issues?fields=id,idReadable,summary,project(shortName,name)")
  [[ "$http_code" == 200 ]] || fail_http "creating" "issue in project $project_reference" "$http_code" "$response_file"
  cat "$response_file"
  printf '\n'
}

link_issues() {
  local issue_id="$1"
  local relation="$2"
  local target_issue_id="$3"
  local command_relation

  if [[ "$issue_id" == "$target_issue_id" ]]; then
    echo "Cannot link issue $issue_id to itself." >&2
    exit 2
  fi

  case "$relation" in
    depends-on) command_relation='depends on' ;;
    required-for) command_relation='is required for' ;;
    parent-for) command_relation='parent for' ;;
    subtask-of) command_relation='subtask of' ;;
    *) usage ;;
  esac

  apply_command "$issue_id" "$command_relation $target_issue_id" "linking"
}

main() {
  (($# >= 1)) || usage
  local operation="$1"
  shift
  configure

  case "$operation" in
    read)
      (($# >= 1)) || usage
      local issue_id
      issue_id=$(resolve_issue_id "$1")
      shift
      read_issue "$issue_id" "$@"
      ;;
    comment)
      (($# == 1)) || usage
      local issue_id
      issue_id=$(resolve_issue_id "$1")
      post_comment "$issue_id"
      ;;
    move)
      (($# == 2)) || usage
      local issue_id
      issue_id=$(resolve_issue_id "$1")
      move_issue "$issue_id" "$2"
      ;;
    assign)
      (($# == 2)) || usage
      local issue_id
      issue_id=$(resolve_issue_id "$1")
      assign_issue "$issue_id" "$2"
      ;;
    create) create_issue "$@" ;;
    link)
      (($# == 3)) || usage
      local issue_id target_issue_id
      issue_id=$(resolve_issue_id "$1")
      target_issue_id=$(resolve_issue_id "$3")
      link_issues "$issue_id" "$2" "$target_issue_id"
      ;;
    *) usage ;;
  esac
}

main "$@"