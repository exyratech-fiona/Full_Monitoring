# v10 — why panels were empty, and the config changes the dashboard cannot fix

---

## ROOT CAUSE (settled 2026-08-11) — one wrong label name

Actual label set on `http_server_request_duration_seconds_count`, read from the Prometheus API:

```json
{"__name__":"http_server_request_duration_seconds_count",
 "deployment_environment":"dev",              <-- NOT deployment_environment_name
 "http_request_method":"POST","http_response_status_code":"200",
 "http_route":"cm_projection_service",
 "instance":"14681aa3-...","job":"Exora-G360_Dev_API_Gateway",
 "k8s_container_name":"api-gateway-backend-dev",
 "k8s_deployment_name":"api-gateway-backend-dev",
 "k8s_namespace_name":"dev-greenfield",
 "k8s_pod_name":"api-gateway-backend-dev-5c4cb54559-xhn77",
 "network_protocol_version":"1.1",
 "service_instance_id":"14681aa3-...","service_name":"Exora-G360_Dev_API_Gateway",
 "service_version":"1.0.0","url_scheme":"http"}
```

Every PromQL query in v6–v10 filtered on `deployment_environment_name=~"$deployment_environment_name"`.
**That label does not exist on the metric series.** In PromQL a regex matcher against an absent
label matches only the empty string, so `deployment_environment_name=~"dev"` selected zero series
— on every panel, in every row, simultaneously.

Why it was so convincing a red herring:

* `target_info` **does** expose `deployment_environment_name`, so
  `label_values(target_info, deployment_environment_name)` happily returned `dev`. The variable
  resolved to a real-looking value that matched nothing downstream.
* Both attribute spellings are listed in `otlp.promote_resource_attributes`, so the config
  looked correct. Only `deployment.environment` is actually emitted — `deployment.environment.name`
  is the semconv 1.27 rename, which this agent build does not send.
* Panels that never referenced the variable (Kubernetes, Node, service graph) kept working,
  which made it look like a datasource or pipeline fault rather than a filter fault.

**Fix applied:** global rename `deployment_environment_name` → `deployment_environment`
(199 occurrences: the Grafana variable, all label matchers, all `$var` references, all
`var-...` data-link parameters). Environment and Namespace variables re-sourced from the metric
itself instead of `target_info`.

**TraceQL is unaffected** — `resource.deployment.environment` was already correct, and this
finding corroborates it.

### Other metric names verified the same way

| Metric | Status |
|---|---|
| `http_server_request_duration_seconds_*`, `http_client_request_duration_seconds_*` | present |
| `db_client_connections_{usage,max,idle_min,pending_requests}` | present |
| `db_client_connections_{create,use,wait}_time_milliseconds_*` | present |
| `db_client_connections_timeouts_total` | **absent** — dead target removed |
| `jvm_cpu_recent_utilization_ratio`, `jvm_cpu_count`, `jvm_cpu_time_seconds_total` | present (v9's `jvm_cpu_utilization_ratio` never existed) |
| `jvm_memory_{used,committed,limit,used_after_last_gc}_bytes` | present |
| `jvm_gc_duration_seconds_*`, `jvm_thread_count`, `jvm_class_*` | present |
| `jvm_file_descriptor_count` | **absent** — dead target removed |
| `traces_span_metrics_calls_total`, `traces_span_metrics_duration_milliseconds_*` | present — collector spanmetrics connector (namespaced) |
| `traces_spanmetrics_calls_total` | present — Tempo metrics-generator, **no** `http_route` dimension |

Note the two near-identical spanmetrics families. `traces_span_metrics_*` (underscore between
*span* and *metrics*) is the collector connector and carries the HTTP dimensions; the fallback
row uses that one. `traces_spanmetrics_*` is Tempo's generator and cannot back an endpoint table
until section 3 below is applied.

---

## CONFIRMED from the first v10 run

The Telemetry Pipeline Health row settled it. Two independent problems:

### Problem 1 — the Service variable was empty (dashboard bug, fixed)

Prometheus' OTLP receiver converts `service.name` into the `job` label and **removes it from
`target_info`**. The option that keeps it, `keep_identifying_resource_attributes`, was only added
in Prometheus **3.2**; you run **2.55**. So `label_values(target_info, service_name)` returns
nothing, while `deployment_environment_name` and `k8s_namespace_name` survive in `target_info`
because they are non-identifying — which is exactly the pattern you saw (Environment and
Namespace populated, Service blank).

With `$service_name` empty, every filter became `service_name=~""` / `resource.service.name = ""`
and matched nothing. That is why *only* the panels which never reference `$service_name`
survived: Kubernetes workload, Node health, and the service dependency map.

Fixed in v10: the Service variable now reads the promoted label off the metric itself —

```promql
label_values(http_server_request_duration_seconds_count{k8s_namespace_name=~"$service_namespace",deployment_environment_name=~"$deployment_environment_name"}, service_name)
```

If it is still blank after reimporting, the metric genuinely is not in Prometheus — see
Problem 2. The alternative source is `label_values(target_info, job)`.

Also added: **panel 1105, "SANITY CHECK"**, at the bottom of the Telemetry Pipeline Health row.
It is deliberately unfiltered and lists every `service_name` / `k8s_namespace_name` /
`deployment_environment_name` / `job` combination that exists on the HTTP metric, plus the age of
the newest sample for each. Rows there but "No data" above means a variable is wrong; no rows
means the pipeline is the problem. That distinction is what cost this round.

### Problem 2 — Prometheus is rejecting ~6% of metric writes (real, still open)

```
sent   otlphttp/prometheus   216.75 ops/s
FAILED otlphttp/prometheus    13.65 ops/s     <-- ~6.3% of metric points dropped
OTLP 400                       0.007 req/s    <-- Prometheus returning HTTP 400
spans  otlp/tempo             0 failed        <-- traces pipeline clean
logs   otlphttp/loki          0 failed        <-- logs pipeline clean
```

Only the metrics leg fails, which is why Tempo kept working throughout. Get the exact reason —
the collector logs the 400 response body verbatim:

```bash
kubectl -n monitoring logs deploy/otel-collector --since=30m \
  | grep -iE "otlphttp/prometheus|Permanent error|400" | tail -40
```

The message will name one of these, and each has a different fix:

| Message contains | Cause | Fix |
|---|---|---|
| `out of order sample` / `too old sample` | batching + two pipelines at different cadences | section 2 below (`out_of_order_time_window`) |
| `duplicate sample for timestamp` | two resources collapsing to one label set | usually `k8s.pod.name` missing on spanmetrics output — give the connector a distinct resource, or drop `k8sattributes` from the metrics pipeline |
| `invalid metric name` / `label name` | a UTF-8 or reserved-name attribute | rename the offending attribute at the source |

Apply section 2 first regardless — it is harmless and covers the most likely case.

### Problem 2 — what the collector log actually proved

```
error exporting items, request to http://prometheus:9090/api/v1/otlp/v1/metrics
responded with HTTP Status Code 400 ... "dropped_items": 2048
```

The collector logs the status code but **truncates the response body**, so the reason is only
visible from the Prometheus side. Two facts are still usable:

* `dropped_items: 2048` is exactly `send_batch_max_size`. Prometheus' OTLP receiver rejects the
  **entire request** on any append error — there is no partial write — so one poisoned sample
  discards a full max-size batch. That alone explains the ~6% loss rate against a low 400 rate.
* Application metrics and connector spanmetrics shared one pipeline, one batch and one exporter,
  so `otelcol_exporter_send_failed_metric_points_total{exporter="otlphttp/prometheus"}` could not
  say which source was at fault.

### Changes applied (2026-08-11)

**`01-prometheus.yaml`** — added a top-level `storage:` block:

```yaml
    storage:
      tsdb:
        out_of_order_time_window: 30m
```

**`05-otel-collector.yaml`** — three changes:

1. `batch.send_batch_size` / `send_batch_max_size` reduced `1024/2048` → `512/512`. Shrinks the
   blast radius of a single bad series from 2048 dropped points to 512.
2. Added a second exporter `otlphttp/prometheus_spanmetrics`, same endpoint, separate queue.
3. Split the single `metrics` pipeline into `metrics/app` (receiver `otlp`, keeps
   `k8sattributes`) and `metrics/spanmetrics` (receiver `spanmetrics`, **no** `k8sattributes`).

Change 3 does two jobs. It isolates the failure, so a bad spanmetrics series can no longer take
the application's metrics down with it. And because
`otelcol_exporter_send_failed_metric_points_total` is labelled by exporter, the Telemetry
Pipeline Health panel will now **name the culprit** — `otlphttp/prometheus` means the app's own
metrics, `otlphttp/prometheus_spanmetrics` means the connector output.

Dropping `k8sattributes` from the spanmetrics pipeline is also a candidate fix in its own right:
connector-generated data has no client connection for `pod_association` to match on, and its
resource attributes were already enriched upstream in the traces pipeline. Running the processor
a second time risks rewriting `k8s.pod.name` and collapsing both api-gateway pods onto one label
set — which Prometheus would reject as duplicate samples for the same timestamp.

### Roll out

```bash
kubectl -n monitoring apply -f 01-prometheus.yaml -f 05-otel-collector.yaml
kubectl -n monitoring rollout restart deploy/prometheus     # config-file change, not hot-reloadable
kubectl -n monitoring rollout restart deploy/otel-collector
```

### Get the actual rejection reason (Prometheus side)

```bash
kubectl -n monitoring logs deploy/prometheus --since=30m \
  | grep -iE "otlp|out of order|duplicate|invalid|append|too old"
```

If `out_of_order_time_window` was the cause, the 400s stop after the restart and this is closed.
If they continue, this log line names which of the remaining two causes it is.

---

## 0. Original triage queries (still useful)

In Prometheus → Graph. These use the `otel-collector-internal` scrape job (port 8888), which is
independent of the broken path, so they answer honestly.

```promql
# 1. Are application metrics reaching Prometheus at all?
sum by (exporter) (rate(otelcol_exporter_send_failed_metric_points_total[5m]))
sum by (exporter) (rate(otelcol_exporter_sent_metric_points_total[5m]))

# 2. Is Prometheus rejecting the OTLP writes?
sum by (code) (rate(prometheus_http_requests_total{handler=~"/api/v1/otlp.*"}[5m]))

# 3. How old is the newest application metric sample?
time() - max(max_over_time(timestamp(
  http_server_request_duration_seconds_count{service_name="Exora-G360_Dev_API_Gateway"}
)[6h:1m]))
```

Query 3 is also the **Metrics freshness** stat pinned to the top-right of the v10 dashboard.
If it reads more than a few hundred seconds, every PromQL panel below it is showing history,
not "now", and no amount of dashboard editing will change that.

Also useful:

```bash
kubectl -n monitoring logs deploy/otel-collector --tail=200 | grep -iE "otlphttp/prometheus|permanent|out of order|429|400"
```

---

## 1. What the reported symptoms actually mean

The failures split cleanly into two groups.

**Group A — every `instant: true` query on an OTLP-pushed metric returned "No data",
while the `range: true` version of the identical query returned a value.**

| Panel | v9 query mode | Result |
|---|---|---|
| P95 Latency (top row, id 6) | range | 4.47 s |
| P95 Latency (golden signals, id 113) | instant | No data |
| Requests / sec (id 111) | instant | No data |
| 5xx % (id 112) | instant | No data |
| JVM Heap % (id 116) | instant | No data |
| Pod Restarts / 1h (id 115) | instant, **kube-state-metrics** | 0 — worked |
| API Endpoint Performance (id 21) | instant | No data |

Same metric, same labels, same filters — only the query mode differs. And the one instant
panel that *did* work reads a scraped metric rather than an OTLP-pushed one.

That is the signature of **stale series**: `rate()` and a bare gauge at `now` need a sample
inside the lookback window (5 m by default, or `$__rate_interval` for `rate`), whereas a range
query with `lastNotNull` reaches back across the whole time range and finds older data.
Prometheus is holding the series but is no longer being fed.

Since Tempo is still receiving traces from the same collector, the traces pipeline is alive and
only the **metrics** leg (`otlphttp/prometheus`) is failing. Queries 1–2 above confirm which.

**Group B — genuinely wrong queries.** These are fixed in the v10 JSON:

| v9 panel | Bug |
|---|---|
| DB Operation Rate / P95 | `db_client_operation_duration_seconds_*` is not emitted by the OTel Java agent for JDBC. Your agent emits `db_client_connections_{create,wait,use}_time_milliseconds_*` and `db_client_connections_usage`. |
| DB Connection Usage (legend "Value") | grouped by `server_address`, which does not exist on that metric. The real labels are `pool_name` and `state`. |
| JVM CPU | `jvm_cpu_utilization_ratio` does not exist. The metric is `jvm_cpu_recent_utilization_ratio`. |
| Average Latency = `0 s` | denominator wrapped in `clamp_min(..., 1)`. At 0.02 rps that divides by 1 instead of 0.02 — a ~50× understatement. Same bug in the 5xx-rate panels. |
| Trace list showing only `OutboxRelay.relay` | TraceQL had no span-kind filter, so background jobs outranked API requests. v10 adds `kind = server && span.http.request.method != nil`. |
| Trace waterfall "No data found in response" | `${traceID}` was empty and the data link on the table used `${__data.fields.traceID}` against a spans-mode frame. |
| Pod panels listing 43 unrelated pods | `$pod_name` defaulted to All with no workload filter. v10 adds a `$k8s_workload` variable and derives pods from it. |
| Doubled row headings | Panels 60/70/80/90/100/110 were `type: "row"` with `w:8,h:6` duplicating the real rows 1016/1019/1027/1035/1043/1051. Removed. |
| `${...:percentcode}` in data links | Not a Grafana format. The correct one is `:percentencode`. |
| `http_method` variable | Hardcoded `"uid": "prometheus"` instead of `${prometheus_datasource}`. |

---

## 2. Config change 1 — Prometheus: accept out-of-order OTLP samples

`01-prometheus.yaml`, in the `prometheus.yml` ConfigMap, add a top-level `storage:` block
(sibling of `global:`, `otlp:`, `scrape_configs:`):

```yaml
    storage:
      tsdb:
        out_of_order_time_window: 30m
```

Why: the OTel Collector batches (`batch.timeout: 5s`) and pushes over OTLP HTTP. Two pipelines
feed the same exporter — the app at a 60 s export interval and the `spanmetrics` connector at
15 s. Samples for a series can therefore land out of order, and with the default
`out_of_order_time_window: 0` Prometheus rejects the write with HTTP 400. This is the single
most common cause of "Prometheus has the series but the newest sample is old" on an OTLP-write
setup, and it matches the Group A symptom exactly.

Then:

```bash
kubectl -n monitoring apply -f 01-prometheus.yaml
kubectl -n monitoring rollout restart deploy/prometheus     # config-file change, not hot-reloadable
```

## 3. Config change 2 — Tempo: give span-metrics the HTTP dimensions

`03-tempo.yaml` currently enables the `span-metrics` processor with **no dimensions**, so
`traces_spanmetrics_calls_total` carries only `service`, `span_name`, `span_kind`, `status_code`.
There is no `http_route`, which is why it cannot back an endpoint table. Replace the `overrides`
block with:

```yaml
    overrides:
      defaults:
        metrics_generator:
          processors: [service-graphs, span-metrics, local-blocks]
          span_metrics:
            dimensions:
              - http.request.method
              - http.route
              - http.response.status_code
              - k8s.namespace.name
              - deployment.environment
            enable_target_info: true
          service_graphs:
            dimensions:
              - http.request.method
              - http.route
```

This gives you a Tempo-side RED source for the endpoint table that survives any future
Prometheus OTLP outage, and it makes the service dependency map filterable.

## 4. Optional — pin the metric export interval

The Java agent's default is 60 s, which is coarse for `$__rate_interval` maths. Add to
`JAVA_TOOL_OPTIONS`:

```
-Dotel.metric.export.interval=15000
```

## 5. Footgun worth knowing about

`instrumentation/otel-operator/instrumentation.yaml` sets `OTEL_LOGS_EXPORTER=none`, while your
`JAVA_TOOL_OPTIONS` sets `-Dotel.logs.exporter=otlp`. The OTel Java SDK resolves system
properties ahead of environment variables, so the `-D` wins and logs do flow — but anything that
drops the `-D` will silently kill the Loki correlation panels. Align the two.

---

## 6. Datasource / panel-type map for every v10 query

| Section | Datasource | Language | Panel type |
|---|---|---|---|
| Metrics freshness | Prometheus | PromQL | Stat |
| Golden signals (8 tiles) | Prometheus | PromQL | Stat |
| Traffic by status class, latency percentiles | Prometheus | PromQL | Time series |
| API Endpoint Performance | Prometheus | PromQL | Table |
| Selected-endpoint rate / percentiles | Prometheus | PromQL | Time series |
| Selected-endpoint distribution | Prometheus | PromQL | Heatmap |
| API Requests, Failed requests, Slowest JDBC spans | Tempo | TraceQL | Table |
| Selected trace waterfall | Tempo | TraceQL | **Traces** |
| Logs for selected trace, error logs | Loki | LogQL | Logs |
| Status distribution | Prometheus | PromQL | Pie chart |
| Top failing endpoints | Prometheus | PromQL | Table |
| Service dependency map | Prometheus | PromQL | Node graph |
| Outbound HTTP, JDBC pool, JVM, Pod, Node | Prometheus | PromQL | Time series |
| Telemetry pipeline health | Prometheus | PromQL | Time series |
