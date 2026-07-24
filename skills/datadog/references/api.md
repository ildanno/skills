# Datadog API Reference

Use this file when a helper request fails or an API-native payload needs
diagnosis. Datadog's generated API reference remains authoritative:
<https://docs.datadoghq.com/api/latest/>.

## Authentication and Sites

The preferred mode sends `DD_ACCESS_TOKEN` as
`Authorization: Bearer <token>` through a temporary mode-`600` curl
configuration. The PAT is standalone; `DD_TOKEN_ID` is public metadata and is
not sent for authentication. When no PAT exists, the helper sends
`DD-API-KEY` and `DD-APPLICATION-KEY`. It removes every credential variable
from the curl child environment.

`DD_SITE=datadoghq.eu` maps to `https://api.datadoghq.eu`; other site suffixes
map the same way.

| Operation | Method and path |
| --- | --- |
| Validate PAT and read identity | `GET /api/v2/current_user` |
| Validate API key | `GET /api/v1/validate` |

A scoped PAT can authenticate successfully while returning 403 from
`current_user`. The helper records identity as unavailable and continues to
the requested endpoint, whose response is the authoritative permission check.

Datadog documents `DD_SITE` using browser sites such as `app.datadoghq.eu`, but
API requests use the corresponding `api.datadoghq.eu` host.

## Supported Endpoints

| Branch | Method and path |
| --- | --- |
| List dashboards | `GET /api/v1/dashboard` |
| Get dashboard | `GET /api/v1/dashboard/{id}` |
| Create dashboard | `POST /api/v1/dashboard` |
| Update dashboard | `PUT /api/v1/dashboard/{id}` |
| Search monitors | `GET /api/v1/monitor/search` |
| Get monitor | `GET /api/v1/monitor/{id}` |
| Create monitor | `POST /api/v1/monitor` |
| Update monitor | `PUT /api/v1/monitor/{id}` |
| Validate monitor | `POST /api/v1/monitor/validate` |
| Validate existing monitor | `POST /api/v1/monitor/{id}/validate` |
| Mute monitor | `POST /api/v1/monitor/{id}/mute` |
| Unmute monitor | `POST /api/v1/monitor/{id}/unmute` |
| Search log events | `POST /api/v2/logs/events/search` |
| Aggregate logs | `POST /api/v2/logs/analytics/aggregate` |
| List pipelines | `GET /api/v1/logs/config/pipelines` |
| Get pipeline | `GET /api/v1/logs/config/pipelines/{id}` |
| Create pipeline | `POST /api/v1/logs/config/pipelines` |
| Update pipeline | `PUT /api/v1/logs/config/pipelines/{id}` |
| Query timeseries | `POST /api/v2/query/timeseries` |
| Query scalar | `POST /api/v2/query/scalar` |
| Get metric metadata | `GET /api/v1/metrics/{name}` |
| Update metric metadata | `PUT /api/v1/metrics/{name}` |
| Get metric tag configuration | `GET /api/v2/metrics/{name}/tags` |
| Create metric tag configuration | `POST /api/v2/metrics/{name}/tags` |
| Update metric tag configuration | `PATCH /api/v2/metrics/{name}/tags` |

The helper intentionally exposes no `DELETE` endpoint and no arbitrary
method/URL passthrough.

## Payload Boundaries

- Dashboard writes require `title`, `layout_type`, and `widgets`.
- Monitor writes require `name`, `type`, `query`, and `message`. Supported
  types are `metric alert`, `log alert`, and `service check`.
- Pipeline writes require `name`, `filter`, and `processors`.
- Metric tag writes use the v2 `manage_tags` envelope:
  `data.type`, `data.id`, and `data.attributes`.
- Partial updates use jq's recursive object merge. Arrays in the patch replace
  arrays in the live object.
- Dashboard exports remove `id`, author, timestamp, and URL response fields.
  Monitor exports remove ID, creator, timestamps, state, downtime, and other
  computed response fields. Pipeline exports remove `id`.

## Generated Dashboard Widgets

The skill can construct these documented widget definitions:

- `timeseries`
- `query_value`
- `toplist`
- `query_table`
- `heatmap`
- `distribution`
- `note`
- `group`

An update can preserve any other API-native widget because the helper does not
rewrite untouched JSON. Supplying `widgets` in a patch replaces the full widget
array.

## Generated Pipeline Processors

The skill can construct:

- grok parser
- date, status, service, and message remappers
- attribute remapper
- category processor
- arithmetic processor

Preserve other processor definitions as API-native JSON. Supplying
`processors` in a patch replaces the full processor array. Datadog warns that
escaped whitespace in returned grok rules may need conversion to `%{space}`
before reusing the JSON in a request.

## Error Semantics

The helper emits structured errors with:

```json
{
  "ok": false,
  "operation": "dashboard.get",
  "status": 403,
  "code": "permission_denied",
  "message": "The application key lacks permission for this operation.",
  "request_id": "..."
}
```

HTTP 429 and 5xx responses retry once only for read or validation requests.
Writes do not retry. A plan's sanitized live configuration is canonically
hashed before the plan is written; apply rereads and hashes the target before
sending a write. Computed monitor state and downtime fields do not create false
configuration conflicts. The plan itself also carries an integrity hash, and
apply derives and verifies the allowed method and path instead of trusting an
edited endpoint.
