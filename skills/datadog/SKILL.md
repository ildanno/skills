---
name: datadog
description: "Datadog operations through the REST API. Use when the user wants to inspect or analyze Datadog logs or metrics, manage dashboards or widgets, manage metric, log, or service-check monitors, configure metric metadata or indexed tags, or manage log pipelines and processors."
---

# Datadog

Use the bundled helper for every Datadog API call. Resolve relative paths from
the directory containing this file. The helper requires Bash, `curl`, and `jq`;
it reads `DD_ACCESS_TOKEN`, `DD_TOKEN_ID`, and `DD_SITE` for Personal Access
Token authentication. It also accepts `DD_API_KEY` plus `DD_APP_KEY` as a
legacy fallback.

Treat every change as a **flight plan**: plan the exact payload, inspect the
target and changed fields, obtain approval, then apply that unchanged plan.

## Steps

1. Resolve the branch and target:
   - **Dashboard:** list, get, export, create, or update dashboards and their
     widgets. Generate timeseries, query-value, toplist, table, heatmap,
     distribution, note, and group widgets. Preserve other widget JSON when
     updating.
   - **Monitor:** list, get, export, create, or update `metric alert`,
     `log alert`, and `service check` monitors; mute or unmute a monitor.
   - **Metrics:** query timeseries or scalar data; read, export, or update
     metadata; read, create, or update indexed-tag and aggregation
     configuration. This skill does not submit metric points.
   - **Logs:** search events or aggregate by time and facets. Use the last 24
     hours in UTC when the user supplies no interval. Search at most 1,000
     events; obtain approval before following another cursor.
   - **Pipeline:** list, get, export, create, or update log pipelines. Generate
     grok, date/status/service/message remappers, attribute remappers, category,
     and arithmetic processors; preserve other processor JSON.

   Use an explicit Datadog ID for updates. When the user gives only a name,
   search first and continue only after one exact match remains. This step is
   complete when the operation, resource, ID or unique match, UTC interval,
   query, and requested output are unambiguous.
2. Check configuration without exposing credentials:
   ```sh
   test -n "${DD_ACCESS_TOKEN:-}" || echo "DD_ACCESS_TOKEN missing"
   test -n "${DD_TOKEN_ID:-}" || echo "DD_TOKEN_ID missing"
   test -n "${DD_SITE:-}" || echo "DD_SITE missing"
   ```
   Prefer the PAT pair. When no PAT is configured, check `DD_API_KEY` and
   `DD_APP_KEY` instead. Direct missing credentials to
   [`README.md`](README.md), and ask the user to set secrets in their terminal
   rather than paste them into chat. Run `bash scripts/datadog.sh verify`;
   state the verified site, authentication mode, token ID, user, and
   organization when returned. This step is complete when one credential mode
   is complete and Datadog validates it for the configured site.
3. Follow a read branch with the matching command from
   [`README.md`](README.md). Reads may run without approval. Always report the
   Datadog query or filter, exact UTC interval, aggregation, page or cursor, and
   limit. Prefer aggregate queries and representative samples for analysis.
   For lists, stop after 100 resources and expose the returned continuation.
   Use `--raw` only when diagnosis needs Datadog's unnormalized read response.
   This step is complete when every requested fact is represented and every
   pagination or sampling boundary is explicit.
4. Prepare a write as JSON matching the Datadog API. Accept the user's existing
   file or create a temporary payload; do not impose a repository source of
   truth. Use `plan-create`, `plan-update`, `plan-mute`, or `plan-unmute` with an
   explicit `--plan-file`.
   - Updates are partial object merges by default; a supplied array replaces
     the complete existing array. Use `--replace` only for an intentional full
     replacement.
   - Create plans block exact-name duplicates. Use `--allow-duplicate` only
     when the user explicitly requests a duplicate.
   - Monitor plans call Datadog's validation endpoint.
   - Metric tag changes can affect custom-metric cardinality and cost; identify
     the tags and aggregations being changed without inventing a cost estimate.

   Inspect the returned target, payload, and every `changed_fields` entry.
   State the exact pending change and plan path. This step is complete when the
   plan represents every requested value and no unrequested field or array
   replacement remains.
5. Obtain explicit approval for that flight plan immediately before applying
   it. Changed payload, target, site, scope, mute end, duplicate policy, or
   replacement mode requires a new plan and fresh approval. After approval,
   run the matching `apply PLAN_FILE --apply` command. The helper rechecks the
   live resource hash and site, refuses stale plans, never retries writes, and
   invalidates the plan after success. This step is complete only when Datadog
   confirms the write and the returned resource ID or metric name matches the
   approved target.
6. On failure, report `operation`, HTTP `status`, `code`, `message`, and
   `request_id` when present. A stale-plan error requires replanning; a 403
   requires the scope documented in [`README.md`](README.md). Reads retry once
   for rate limits or server errors, respecting `Retry-After`; writes require a
   new user-requested attempt and fresh approval. For endpoint or payload
   diagnosis, read [`references/api.md`](references/api.md). This step is
   complete when authentication, permission, validation, conflict, missing
   resource, concurrency, and rate-limit failures are distinguished.

The helper has no delete, pipeline-order, log-index, archive, exclusion-filter,
downtime, raw log-ingest, or metric-submission command.
