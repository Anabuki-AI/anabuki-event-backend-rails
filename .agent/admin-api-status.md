# Admin API status integration

## Endpoint and authorization

`GET /api/admin/api-status` is a management-only endpoint. It uses the same device-bound management session and Pundit `MANAGEMENT_PAGE_VIEW` permission as the existing management APIs. It returns `401` without a valid session and `403` for an applicant session. Browser responses set `Cache-Control: no-store`; credentials and configured metric queries never appear in the response.

The frontend should call this same-origin backend URL after obtaining a management session:

```text
GET /api/admin/api-status
```

The endpoint is read-only. The backend caches provider snapshots for `API_STATUS_CACHE_TTL_SECONDS` (default 60; `0` disables it) to protect upstream APIs. A cache hit has `cached: true`; `generatedAt` and provider `fetchedAt` remain the original collection time.

## Response contract

All states are explicit. `unconfigured`, `error`, `unavailable`, and `not_provided` must not be rendered as a healthy service.

```json
{
  "generatedAt": "2025-09-01T12:00:00Z",
  "cached": false,
  "providers": [
    {
      "provider": "statuspage",
      "source": "Statuspage",
      "state": "available",
      "fetchedAt": "2025-09-01T12:00:00Z",
      "availability": {
        "state": "available",
        "value": "operational",
        "externalStatus": "All Systems Operational"
      },
      "metrics": {
        "errorRate": { "state": "not_provided", "value": null, "unit": "percent" },
        "responseTime": { "state": "not_provided", "value": null, "unit": "milliseconds" }
      }
    },
    {
      "provider": "datadog",
      "source": "Datadog",
      "state": "available",
      "fetchedAt": "2025-09-01T12:00:00Z",
      "availability": { "state": "not_provided", "value": null },
      "metrics": {
        "errorRate": {
          "state": "available",
          "value": 0.42,
          "unit": "percent",
          "observedAt": "2025-09-01T11:59:00Z",
          "fetchedAt": "2025-09-01T12:00:00Z"
        },
        "responseTime": {
          "state": "available",
          "value": 183.4,
          "unit": "milliseconds",
          "observedAt": "2025-09-01T11:59:00Z",
          "fetchedAt": "2025-09-01T12:00:00Z"
        }
      }
    }
  ]
}
```

`statuspage.availability.value` is one of `operational`, `degraded`, `partial_outage`, `major_outage`, or `unknown`. A provider `state` is one of `available`, `partial`, `unconfigured`, or `error`. A metric state is one of `available`, `unconfigured`, `unavailable` (successful upstream response but no sample), `error`, or `not_provided`.

When both configured Datadog queries succeed but contain no samples, each metric is `unavailable` with a `no_data` issue while the aggregate provider state remains `unconfigured`. This is pinned compatibility behavior pending explicit provider-state contract agreement; clients must use the per-metric states and must not infer that this aggregate state proves missing configuration.

Finite Datadog values currently pass through without semantic range validation: an error-rate value outside `0..100` or a negative response time remains `available`. **TODO:** agree whether a future contract revision rejects or classifies those values. Do not silently clamp them.

## Provider setup

All values are local/deployment environment variables. Do not commit keys or metric queries.

### Statuspage

Choose one of these modes:

1. **Public status page:** Set `STATUSPAGE_PUBLIC_SUMMARY_URL` to the exact HTTPS `.../api/v2/summary.json` URL published by the Statuspage page. No Statuspage credential is sent.
2. **Authenticated Statuspage Developer API:** Set `STATUSPAGE_PAGE_ID`, `STATUSPAGE_API_KEY`, and optionally `STATUSPAGE_API_BASE_URL` (default `https://api.statuspage.io/v1`). The backend requests `GET /pages/:page_id` using `Authorization: OAuth ...`.

The public summary mode takes precedence when both are present. The authenticated key needs read access to that page. Verify the selected page and external components in Statuspage before adding it to the dashboard.

### Datadog

Set `DATADOG_API_KEY`, `DATADOG_APP_KEY`, and the two metrics queries. The integration calls Datadog's v2 `POST /api/v2/metrics/query`; it uses `DATADOG_SITE` (default `datadoghq.com`) or the full HTTPS `DATADOG_API_BASE_URL` for another Datadog site.

- `DATADOG_ERROR_RATE_QUERY` must yield a percentage value. Configure its metric/formula at the source so `value` is percent, not a 0-1 ratio.
- `DATADOG_RESPONSE_TIME_QUERY` must yield milliseconds.
- `DATADOG_METRICS_WINDOW_SECONDS` controls the lookback window (60-3600, default 300).

Use an app key with only the metrics-query permission and an API key scoped to the appropriate deployment where provider key scoping is available. Validate queries in Datadog Metrics Explorer before configuring them. The dashboard endpoint intentionally never returns either key or the query text.

## Operational behavior

External connections are HTTPS-only, have 3-second connect and 5-second read/write timeouts, and convert non-2xx responses, parse failures, network failures, and TLS/certificate failures to generic `upstream_error` objects. TLS exception class/message details are not returned. This avoids leaking provider details and leaves the UI with a stable, non-healthy state when integrations are absent or unavailable; a failed provider does not prevent another provider's result from being returned.
