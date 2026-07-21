# YouTrack API

Read this reference only when the bundled helper fails or a read needs fields it
does not request.

## Connection

- Instance URL: `$YOUTRACK_URL`
- API URL: `${YOUTRACK_URL%/}/youtrack/api`
- Default project: `$YOUTRACK_PROJECT`
- Authentication: `Authorization: Bearer $YOUTRACK_TOKEN`
- Media type: `application/json`

Keep configuration in the environment. Check only whether the token is present
and redact authorization headers from diagnostics. Use `YOUTRACK_PROJECT` to
expand a bare issue number before making a request.

## Issue Thread

- Issue: `GET /issues/{idReadable}?fields={fields}`
- Comments: `GET /issues/{idReadable}/comments?fields={fields}`
- Add comment: `POST /issues/{idReadable}/comments?fields={fields}` with body
  `{"text":"comment text"}`

Generate request bodies with a JSON encoder so multiline text, quotes, and
backslashes retain their meaning. The helper uses `jq`.

## Create an Issue

Creating an issue requires the entity ID of its project:

1. Resolve the exact project short name with
   `GET /admin/projects?fields=id,name,shortName&query={project}`.
2. Create the issue with `POST /issues?fields={fields}` and body:
   ```json
   {
     "project": {"id": "0-0"},
     "summary": "Summary",
     "description": "Optional description"
   }
   ```

The helper rejects zero or multiple exact project matches instead of choosing a
fuzzy result.

## Commands

Move, assign, and link operations use `POST /commands?fields={fields}`:

```json
{
  "query": "State In Progress",
  "issues": [{"idReadable": "DEMO-403"}]
}
```

The helper emits these command queries:

| Operation | Query |
| --- | --- |
| Move to a column | `<YOUTRACK_COLUMN_FIELD or State> <column>` |
| Assign | `for <login>` |
| Depends on | `depends on <target ID>` |
| Required for | `is required for <target ID>` |
| Parent | `parent for <target ID>` |
| Child | `subtask of <target ID>` |

Link commands are directional. Applying `depends on DEMO-401` to `DEMO-403`
means DEMO-403 depends on DEMO-401. Applying `parent for DEMO-404` to DEMO-403
means DEMO-403 is the parent and DEMO-404 is its subtask.

## Responses

- `200`: successful read, creation, comment, or command
- `400`: malformed request or unsupported field expression
- `401`: missing, expired, or invalid token
- `403`: authenticated user lacks permission
- `404`: issue is absent or hidden from the authenticated user

Treat the response body as diagnostic data. Preserve the HTTP status while
summarizing it, and omit secrets or authorization headers.