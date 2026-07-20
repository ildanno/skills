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
backslashes retain their meaning. The helper uses Python's `json` module.

## Responses

- `200`: successful read or comment creation
- `400`: malformed request or unsupported field expression
- `401`: missing, expired, or invalid token
- `403`: authenticated user lacks permission
- `404`: issue is absent or hidden from the authenticated user

Treat the response body as diagnostic data. Preserve the HTTP status while
summarizing it, and omit secrets or authorization headers.