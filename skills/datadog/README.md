# Datadog Skill

This skill reads and analyzes Datadog logs and metrics and manages dashboards,
monitors, metric configuration, and log pipelines through the official REST
API. Writes are dry-run first: the helper creates a credential-free plan file,
and only a later command with `--apply` can send it.

## Requirements

- Bash
- `curl`
- `jq`
- `shasum` or `sha256sum`
- A scoped Datadog Personal Access Token, or an API and application key pair

## Configure the Environment

### Personal Access Token

PAT authentication is standalone and preferred. Set the secret and its public
token ID in the terminal. `DD_TOKEN_ID` is reported as audit metadata but is
not sent as authentication material:

```bash
read -r -s -p "Datadog Personal Access Token: " DD_ACCESS_TOKEN
printf '\n'
export DD_ACCESS_TOKEN
export DD_TOKEN_ID='PUBLIC_TOKEN_ID'
export DD_SITE=datadoghq.eu
```

The secret starts with `ddpat_`. Create a token under
[Personal Settings > Access Tokens](https://app.datadoghq.eu/personal-settings/access-tokens),
select the scopes required by the table below, and copy the secret when
Datadog displays it. The secret is shown only once.

### API and Application Key Fallback

When `DD_ACCESS_TOKEN` is absent, the helper accepts the legacy pair:

```bash
read -r -s -p "Datadog API key: " DD_API_KEY
printf '\n'
read -r -s -p "Datadog application key: " DD_APP_KEY
printf '\n'
export DD_API_KEY DD_APP_KEY
export DD_SITE=datadoghq.eu
```

Other examples include `datadoghq.com`, `us3.datadoghq.com`,
`us5.datadoghq.com`, `ap1.datadoghq.com`, `ap2.datadoghq.com`,
`uk1.datadoghq.com`, and `ddog-gov.com`. Keep keys out of repositories,
terminal history, and chat. Use the narrowest scopes that cover the required
branches.

| Branch | PAT or application-key scopes |
| --- | --- |
| Verify | No additional scope for PAT current-user verification |
| Dashboard read/write | `dashboards_read`, `dashboards_write` |
| Monitor read/write | `monitors_read`, `monitors_write` |
| Monitor mute/unmute | `monitors_read`, `monitors_write`, `monitors_downtime` |
| Metric queries | Access to metrics visible to the key owner |
| Metric metadata write | `metrics_metadata_write` |
| Metric tag configuration write | `metric_tags_write` |
| Log search/aggregate | `logs_read_data`, `logs_read_index_data` |
| Pipeline read | `logs_read_config` |
| Pipeline write | `logs_write_pipelines`, plus `logs_write_processors` where processor-level restrictions apply |

See Datadog's documentation for
[Personal Access Tokens](https://docs.datadoghq.com/account_management/personal-access-tokens/),
[API and application keys](https://docs.datadoghq.com/account_management/api-app-keys/)
and [RBAC permissions](https://docs.datadoghq.com/account_management/rbac/permissions/).

## Verify

Every helper invocation validates its selected credential before its operation.
PAT mode calls the current-user endpoint; legacy mode validates the API key.
Run the standalone check when setting up the skill:

```sh
bash scripts/datadog.sh verify
```

The output identifies the configured site, API base, and authentication mode
without printing a secret. PAT mode also reports `DD_TOKEN_ID` and a minimal
user and organization identity when the PAT permits `current_user`. A 403 from
that identity probe does not block another operation: the requested endpoint
performs the authoritative scope check.

## Read Dashboards, Monitors, and Pipelines

Lists return at most 100 resources:

```sh
bash scripts/datadog.sh dashboard list --name "checkout" --limit 50
bash scripts/datadog.sh dashboard list --page 1
bash scripts/datadog.sh monitor list --query 'tag:team:payments' --limit 100
bash scripts/datadog.sh pipeline list --name "nginx" --limit 50 --offset 0
```

Read or export one resource:

```sh
bash scripts/datadog.sh dashboard get DASHBOARD_ID
bash scripts/datadog.sh monitor get 123456
bash scripts/datadog.sh pipeline get PIPELINE_ID

bash scripts/datadog.sh dashboard export DASHBOARD_ID >dashboard.json
bash scripts/datadog.sh monitor export 123456 >monitor.json
bash scripts/datadog.sh pipeline export PIPELINE_ID >pipeline.json
```

`get` emits the stable helper envelope. `export` emits sanitized API-native JSON
that can be versioned or used as a later input. Add `--raw` to a read command
only when the original Datadog response is required for diagnosis.

## Analyze Logs

Search defaults to the last 24 hours in UTC and 100 events. The maximum is
1,000 events per request:

```sh
bash scripts/datadog.sh logs search \
  --query 'service:checkout status:error' \
  --limit 200

bash scripts/datadog.sh logs search \
  --query 'service:checkout @http.status_code:[500 TO 599]' \
  --from 2026-07-23T08:00:00Z \
  --to 2026-07-24T08:00:00Z \
  --limit 1000
```

Continue only after reviewing the first page:

```sh
bash scripts/datadog.sh logs search \
  --query 'service:checkout status:error' \
  --cursor 'CURSOR_FROM_PREVIOUS_RESPONSE'
```

Pass an API-native
[logs aggregate](https://docs.datadoghq.com/api/latest/logs/#aggregate-events)
request to calculate trends, facet groups, and top errors. Missing
`filter.from` or `filter.to` values default to the last 24 hours:

```sh
bash scripts/datadog.sh logs aggregate --input aggregate.json
```

## Query Metrics

Timeseries and scalar commands accept API-native Datadog v2 query payloads:

```sh
bash scripts/datadog.sh metrics timeseries --input timeseries-query.json
bash scripts/datadog.sh metrics scalar --input scalar-query.json
```

Run separate queries for period comparisons. Group by tags in the payload and
use the returned series to identify peaks and drops.

Read and export metric configuration:

```sh
bash scripts/datadog.sh metrics metadata get custom.checkout.duration
bash scripts/datadog.sh metrics metadata export custom.checkout.duration
bash scripts/datadog.sh metrics tags get custom.checkout.duration
bash scripts/datadog.sh metrics tags export custom.checkout.duration
```

## Plan and Apply Writes

Payloads are JSON objects read from a file or standard input. A create or update
command writes a mode-`600` plan containing the site, target, proposed payload,
changed top-level fields, configuration hash, and plan-integrity hash. It
contains no keys.

Create a dashboard:

```sh
bash scripts/datadog.sh dashboard plan-create \
  --input dashboard.json \
  --plan-file /tmp/dashboard-create.plan.json

bash scripts/datadog.sh dashboard apply \
  /tmp/dashboard-create.plan.json --apply
```

Create plans block exact-name duplicates. An intentional duplicate must be
planned with `--allow-duplicate` and approved as such.

Update only supplied object fields:

```sh
bash scripts/datadog.sh monitor plan-update 123456 \
  --input monitor.patch.json \
  --plan-file /tmp/monitor-update.plan.json

bash scripts/datadog.sh monitor apply \
  /tmp/monitor-update.plan.json --apply
```

Objects merge recursively. Arrays present in a patch replace the complete live
array. Use `--replace` for a deliberate full replacement:

```sh
bash scripts/datadog.sh pipeline plan-update PIPELINE_ID \
  --input pipeline.json \
  --replace \
  --plan-file /tmp/pipeline-replace.plan.json
```

Monitor create and update plans accept only `metric alert`, `log alert`, and
`service check` payloads and call Datadog's validation endpoint before writing
the plan.

Mute and unmute require an explicit scope. A finite mute uses a whole-second UTC
end; an indefinite mute must say so:

```sh
bash scripts/datadog.sh monitor plan-mute 123456 \
  --scope 'env:production' \
  --end 2026-07-24T12:00:00Z \
  --plan-file /tmp/monitor-mute.plan.json

bash scripts/datadog.sh monitor plan-mute 123456 \
  --scope '*' \
  --indefinite \
  --plan-file /tmp/monitor-mute-indefinite.plan.json

bash scripts/datadog.sh monitor plan-unmute 123456 \
  --scope 'env:production' \
  --plan-file /tmp/monitor-unmute.plan.json
```

Metric metadata and indexed-tag configuration use the same flight-plan model:

```sh
bash scripts/datadog.sh metrics metadata plan-update custom.checkout.duration \
  --input metadata.patch.json \
  --plan-file /tmp/metadata.plan.json

bash scripts/datadog.sh metrics tags plan-create custom.checkout.duration \
  --input tags.json \
  --plan-file /tmp/tags-create.plan.json

bash scripts/datadog.sh metrics tags plan-update custom.checkout.duration \
  --input tags.patch.json \
  --plan-file /tmp/tags-update.plan.json
```

Apply through the matching branch:

```sh
bash scripts/datadog.sh metrics metadata apply /tmp/metadata.plan.json --apply
bash scripts/datadog.sh metrics tags apply /tmp/tags-update.plan.json --apply
```

If the live configuration, plan contents, or `DD_SITE` changes after planning,
apply fails. Runtime monitor state changes do not invalidate a configuration
plan. Generate a new plan, inspect it, and approve it again. Successful apply
removes the plan file. Writes are never retried automatically.

## Tests

Run the offline suite:

```sh
bash tests/test_datadog.sh
```

Run the optional live read-only smoke test only with configured credentials:

```sh
DD_LIVE_TEST=1 bash tests/test_datadog_live.sh
```

The live test only validates credentials and lists one dashboard.
