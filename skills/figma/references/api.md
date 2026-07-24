# Figma REST API Reference

Load this reference when diagnosing a helper failure or constructing a manual
request. The helper fixes the API origin to `https://api.figma.com/v1` and sends
the personal access token in the `X-Figma-Token` header.

## Resources

A resource may be a file key or an HTTPS URL with one of these paths:

```text
https://www.figma.com/design/FILE_KEY/NAME
https://www.figma.com/file/FILE_KEY/NAME
https://www.figma.com/proto/FILE_KEY/NAME
https://www.figma.com/board/FILE_KEY/NAME
```

Figma URLs encode node IDs such as `12:34` as `node-id=12-34`. The helper
normalizes hyphen separators before calling the API.

## Endpoints

| Helper command | Request |
| --- | --- |
| `verify` | `GET /me` |
| `read-file` | `GET /files/:key?depth=:depth` |
| `read-nodes` | `GET /files/:key/nodes?ids=:ids[&depth=:depth]` |
| `read-comments` | `GET /files/:key/comments?as_md=true` |
| `add-comment` | `POST /files/:key/comments` |
| `reply-comment` | `GET /files/:key/comments?as_md=true`, then `POST /files/:key/comments` |

`GET /files/:key` counts depth from the document root: depth 1 returns pages,
and depth 2 also returns the top-level objects on each page. For
`GET /files/:key/nodes`, depth is counted from each requested node. A node entry
may be `null` when the ID does not exist or is not visible.

The helper requests the current file version and excludes `geometry=paths`,
plugin data, branch metadata, and image rendering.

## Comment Payloads

A general comment contains only its message:

```json
{
  "message": "Please review this flow.\n"
}
```

An anchored comment uses Figma's `FrameOffset` shape. `node_id` identifies the
frame and `node_offset` is relative to its top-left corner:

```json
{
  "message": "Please review this frame.\n",
  "client_meta": {
    "node_id": "12:34",
    "node_offset": {
      "x": 20,
      "y": 40
    }
  }
}
```

A reply names a root comment:

```json
{
  "message": "Addressed.\n",
  "comment_id": "123456789"
}
```

Figma rejects replies whose `comment_id` is itself a reply. The helper resolves
a supplied reply ID through its `parent_id` before posting.

## Scopes

| Endpoint | Scope |
| --- | --- |
| `GET /me` | `current_user:read` |
| File and node reads | `file_content:read` |
| Comment reads | `file_comments:read` |
| Comment posts | `file_comments:write` |

Scopes are an upper bound. The token can access only files available to its
Figma account.

## Failures

- HTTP 400: invalid parameter or payload.
- HTTP 401: authentication failure.
- HTTP 403: invalid or expired token, missing scope, or insufficient access.
- HTTP 404: missing or invisible file.
- HTTP 429: rate limit. Read `Retry-After`; the helper does not retry.
- HTTP 5xx: Figma service failure.

Figma may apply very small request budgets based on the token owner's seat and
the plan containing the requested file. Batch node IDs in one `read-nodes`
request when possible.

## Official Documentation

- [Authentication](https://developers.figma.com/docs/rest-api/authentication/)
- [Personal access tokens](https://developers.figma.com/docs/rest-api/personal-access-tokens/)
- [Scopes](https://developers.figma.com/docs/rest-api/scopes/)
- [File endpoints](https://developers.figma.com/docs/rest-api/file-endpoints/)
- [Comment endpoints](https://developers.figma.com/docs/rest-api/comments-endpoints/)
- [Rate limits](https://developers.figma.com/docs/rest-api/rate-limits/)
- [OpenAPI specification](https://github.com/figma/rest-api-spec)
