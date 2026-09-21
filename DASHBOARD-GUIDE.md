# Dashboard Guide — Exora G360 Single-Window Request Investigation

Panel-by-panel reference for `Exora_G360_SRE_API_Dashboard_v10.json`. For the
underlying stack, see `ARCHITECTURE.md`; for a general investigation workflow,
see `DEVELOPER-GUIDE.md`. This doc answers, section by section: **what it is,
why it exists, how to investigate further from it.**

The dashboard's own built-in panels — "How to use this dashboard" and "The
investigation path" — give the short version. This is the long version.

---

## Filter bar (top of dashboard)

| Filter | What it is | Why it exists |
|--------|-----------|----------------|
| `Metrics DS` / `Traces DS` / `Logs DS` | Datasource-selector variables, defaulted to Prometheus / Tempo / Loki | Lets you repoint the whole dashboard at a different datasource (e.g. a staging Prometheus) without editing every panel |
| `Environment` | Filters to `deployment_environment="dev"` | Multiple environments (`dev`, `sit`, `demo`, …) share this cluster; this scopes everything below to one |
| `Namespace` / `Service` / `Deployment` / `Pod` / `Node` | Standard drill-down chain from broad to specific | Start at `All`, narrow only when you have a reason to — narrowing too early hides the bigger picture |
| `API Route` / `Method` | Filters every panel to one endpoint | Use *after* the API Endpoint Performance table tells you which route to look at, not before |
| `Log level` | Defaults to `error and warn` | Keeps the log panel from being drowned in INFO noise; switch to `All` if you suspect the issue is logged below WARN |
| `Selected Trace ID` | Manually paste a trace ID, or it auto-fills when you click a row in API Requests | This is what makes the waterfall/logs-for-trace panels below populate |
| `Trace min duration` / `Trace min HTTP status` | Pre-filters the trace list | Set `min duration=500ms` to jump straight to slow requests instead of scrolling |

**How to investigate further:** the filter bar *is* the investigation path —
narrow left to right (Environment → Service → Route) rather than trying to
read the raw firehose.

---

## START HERE — Metric Discovery

**What it is:** a small "is data even flowing" sanity panel, meant to be
opened first whenever the rest of the dashboard looks empty.

**Why it exists:** every panel below depends on the OTel Java agent
successfully exporting to the Collector and the Collector successfully
exporting to Prometheus. When that chain breaks anywhere, every other panel
goes blank simultaneously and it's easy to mistake that for "the app has no
traffic."

**How to investigate further:** if this shows no series either, don't debug
the dashboard — go to the **Telemetry Pipeline Health** section at the bottom
instead; the fault is upstream of Grafana.

## SPANMETRICS FALLBACK

**What it is:** the same RED metrics (rate, errors, duration), rebuilt from
`calls_total` / `duration_milliseconds_bucket` — the Collector's `spanmetrics`
connector output — instead of the app's own OTLP metrics.

**Why it exists:** these two data sources are produced independently (see
`ARCHITECTURE.md`'s note on the split `otlphttp/prometheus` /
`otlphttp/prometheus_spanmetrics` exporters). If the app's direct OTLP metrics
pipeline breaks but traces are still arriving, this panel still works because
it's derived from traces, not from the app's own metric export.

**How to investigate further:** if the main Golden Signals panels are empty
but this fallback has data, the problem is specifically in the
`metrics/app` Collector pipeline (or the app's own OTLP metrics export), not
in tracing or the Collector as a whole.

## GOLDEN SIGNALS — SERVICE LEVEL

**What it is:** the four classic SRE signals for this one service —
requests, error rate, latency (avg/p95/p99) — plus a status-class breakdown
and latency percentile table.

**Why it exists:** this is the "is the service healthy right now" summary.
Everything else on the dashboard is either upstream context (K8s/node health)
or downstream drill-down from an anomaly spotted here.

**How to investigate further:**
- P95/P99 far above the average (here: 1.77s / 3.53s vs. 168ms avg) is normal
  for a low-traffic, bursty service — a handful of slow outliers dominate the
  tail even when most requests are fast. Don't chase the tail on a handful of
  samples; confirm it's a *pattern* in API Endpoint Performance first.
- A nonzero 4xx/5xx rate → go straight to **Error Investigation** below.
- Latency creeping up service-wide (not one endpoint) → check **JVM Runtime
  Health** (GC pauses, heap pressure) and **Database/JDBC Connection Pool**
  (pool exhaustion causes exactly this pattern) before assuming app code.

## API Endpoint Performance

**What it is:** the same RED metrics, broken out per `(method, route)` —
requests, RPS, avg/p50/p95/p99 latency, 2xx/4xx count, error %.

**Why it exists:** this is where "the service is slow" becomes "*this specific
endpoint* is slow" — the necessary next step before opening any individual
trace.

**How to investigate further:** click a row. It sets the `API Route`/`Method`
filters, which cascades into every panel below — **Selected Endpoint** and
**API Requests** now show only that route. Look for endpoints where P99 is
many multiples of P50 (like `/dashboard/insights/applications` here: 687ms P50
vs. 2.43s P99) — that gap is exactly what you'd want a trace for.

## Selected Endpoint (request rate / latency percentiles / latency heatmap)

**What it is:** the time-series view of whatever endpoint you clicked above —
request rate by status, P50/P95/P99 over time, and a latency heatmap.

**Why it exists:** a single aggregate P99 number hides *when* it happened. The
heatmap in particular shows whether slowness is one outlier vs. a sustained
band — a horizontal stripe of yellow/red across the whole time range means a
persistent problem; a single hot cell means a one-off.

**How to investigate further:** find the time bucket where latency spiked,
narrow the dashboard's overall time range to it, then go to **API Requests**
below to pick an actual trace from that exact window.

## Request Journey — API Requests (Tempo)

**What it is:** a row-per-request list of real traces for the currently
selected route/filters — trace ID, span ID, HTTP attributes, pod, duration.

**Why it exists:** this is the bridge from "aggregate metrics say something is
slow" to "here is one concrete example, click it." Every column here is a
resource attribute promoted by the Collector's `k8sattributes` processor and
the app's own resource attributes (see `01-prometheus.yaml`'s
`promote_resource_attributes`), which is why you get `k8s.pod.name` and
`service.version` right in the row without leaving this table.

**How to investigate further:** sort by duration (or set `Trace min duration`
in the filter bar) to jump straight to the slow ones. Click a row — the trace
ID populates the `Selected Trace ID` variable, and the waterfall + logs panels
below load automatically.

## Selected Trace — Full Waterfall

**What it is:** the span tree for one specific trace ID — HTTP → Controller →
Service → Repository → JDBC → SQL → DB → any downstream call — each drawn
proportional to its duration.

**Why it exists:** this is the actual root-cause view. See
`DEVELOPER-GUIDE.md` §3 Step 3 for how to read it — briefly: the widest bar is
where the time went, a gap before a child span starts usually means queueing
(thread pool / connection pool wait) rather than the call itself being slow,
and a red span has captured exception details.

**How to investigate further:** click into the widest/reddest span. If it's a
JDBC/SQL span, cross-reference **Database/JDBC Connection Pool** for the same
timestamp — a slow query and a saturated pool often show up together. If it's
a downstream HTTP call, check **Service Topology & Outbound Dependencies**
for that destination's general health, not just this one request.

## Logs for the Selected Trace

**What it is:** every log line the app emitted during that specific trace,
pulled from Loki filtered to that exact `trace_id`.

**Why it exists:** the trace tells you *what took long*; the logs tell you
*why* — stack traces, business-logic branches, retry attempts — that never
show up as span attributes. This only works because Loki's
`allow_structured_metadata: true` (see `04-loki.yaml`) preserves `trace_id` as
a queryable field instead of flattening it into the log body.

**How to investigate further:** if this is empty for a trace you know is
slow/erroring, either the app isn't logging anything notable for that request
(check `Log level` — try `All`), or the log genuinely didn't happen — which is
itself useful information (e.g. a timeout with no corresponding error log
suggests the failure was infrastructure-level, not application-level).

## Failed Requests

**What it is:** the same trace list as API Requests, pre-filtered to
errors/5xx only.

**Why it exists:** a fast way to see *only* the bad requests without manually
setting `Trace min HTTP status`.

**How to investigate further:** "No data" here with a nonzero error rate in
Golden Signals means the errors are 4xx, not 5xx (4xx isn't "failed" in the
infra sense — it's usually a client/auth problem). Check **Top failing
endpoints** in Error Investigation instead.

## Slowest JDBC / SQL Spans

**What it is:** every database span across all recent traces, sorted slowest
first, with `db.name`, `db.operation`, `db.sql.table`, `db.statement`.

**Why it exists:** database latency is one of the most common root causes of
API slowness, and this surfaces it *across* requests instead of one trace at
a time — you can spot "every call to this table is slow" as a pattern rather
than discovering it trace-by-trace.

**How to investigate further:** if the same `db.sql.table` / `db.operation`
keeps appearing, that's a candidate for a missing index or a query that needs
optimizing — take the `db.statement` to whoever owns the schema. Note in the
sample data these are all sub-15ms `OutboxRelay.drain` background-job queries,
not user-request-path queries — worth distinguishing background job DB load
from request-path DB load when reading this table.

## Trace list (fallback)

**What it is:** a plain, guaranteed-clickable list of recent trace IDs with
minimal columns.

**Why it exists:** a safety net for when the richer API Requests table's
extra columns/filters aren't rendering correctly (panel query errors, plugin
issues) — this simpler query is less likely to break.

**How to investigate further:** use this if the main table above ever shows
an error or unexpectedly empty state that the rest of the dashboard suggests
shouldn't be empty.

## Error Investigation

**What it is:** HTTP status-code distribution and a table of top failing
endpoints by status code.

**Why it exists:** separates "the system is broken" (5xx) from "clients are
doing something the API rejects" (4xx) — very different response, very
different owner.

**How to investigate further:** a concentration of 401s on specific endpoints
(as in this data — `/users`, `/assessment-plans`, `/org-units`) is usually
expired/missing auth tokens, not an app bug — check whether these correlate
with a token-expiry window or a specific client/integration before treating
it as an incident. A concentration of 5xx on one endpoint sends you straight
back to **API Endpoint Performance** → click that row → find a failed trace.

## Service Topology & Outbound Dependencies

**What it is:** a node-graph of what calls this service and what this
service calls outbound, plus per-destination rate/latency/error tables.

**Why it exists:** most production incidents aren't "my code is slow," they're
"a thing I depend on is slow." This shows every outbound call the app makes —
including third-party APIs like `api.anthropic.com` — with the same RED
metrics as the app's own inbound traffic.

**How to investigate further:** if the app is slow and one outbound
destination shows elevated P95/P99 or nonzero 5xx%, that's very likely the
root cause, not the app itself. Remember the P95>P99 sample-size caveat noted
at the top of this doc — verify a percentile anomaly against raw call count
before treating it as a finding.

## Database / JDBC Connection Pool

**What it is:** HikariCP pool metrics (Micrometer, via the Java agent) — used
vs. idle connections, saturation, pending requests, connection wait/use/create
timing.

**Why it exists:** a maxed-out connection pool produces symptoms that look
exactly like "the app is randomly slow" in the Golden Signals panel, but the
actual cause is upstream of any single request — requests queue waiting for a
free connection before they even start their DB work.

**How to investigate further:** rising **pending connection requests** or
**wait time** alongside **used ≈ max** is the pool-exhaustion signature.
Cross-check against the JDBC waterfall gap described above — a request whose
JDBC span starts long after its parent span started, with no other work in
between, is very likely waiting on this exact pool.

## JVM Runtime Health

**What it is:** heap (used/committed/max, live-set-after-GC), non-heap by
pool, GC time/pause/frequency, thread counts by state, loaded classes.

**Why it exists:** this is infrastructure health *inside* the process — the
layer between "the container has enough memory" (Kubernetes Workload, below)
and "the request is slow" (traces). The alerting rules `JVMHeapHigh` and
`JVMHighGCPause` (see `09-prometheus-rules.yaml`) are built directly from
these same metrics.

**How to investigate further:** heap climbing toward max with GC pause time
also climbing is the classic memory-pressure pattern — check for a leak or
reduce load before it OOMs. A high `runnable` thread count with rising
latency suggests CPU contention; a high `timed_waiting`/`waiting` count
alongside connection-pool pressure above suggests threads blocked on I/O, not
CPU-bound work.

## Kubernetes Workload — api-gateway-backend-dev

**What it is:** the container-orchestration view of this specific
Deployment — replica readiness, restarts, OOMKills, CPU throttling, pod
phase, CPU/memory vs. request/limit, network I/O.

**Why it exists:** this answers "is the platform underneath this app okay,"
independent of application-level metrics. A pod being OOMKilled or CPU
throttled explains application-level slowness that no amount of code-level
investigation will find.

**How to investigate further:** nonzero **OOMKilled containers** or **CPU
throttling %** here fully explains erratic latency upstream — stop looking at
traces and go raise the pod's resource limits (see the Prometheus OOM
incident in `ARCHITECTURE.md` §5 for exactly this pattern playing out on a
different component). Restarts > 0 in the selected range should be
cross-referenced with the `PodRestartingFrequently` / `PodCrashLoopBackOff`
alerts from `09-prometheus-rules.yaml`.

## Node Health

**What it is:** the underlying Kubernetes node's CPU/memory/disk/network
(from Node Exporter), collapsed by default (8 panels).

**Why it exists:** the layer below Kubernetes Workload — if the *node* is
under memory or CPU pressure, every pod on it suffers, not just this one.
This is the same data behind the `HighNodeCPU`/`HighNodeMemory`/
`HighDiskUsage` alerts.

**How to investigate further:** if Kubernetes Workload metrics for this pod
look fine but latency is still erratic, expand this section — noisy-neighbor
pressure from *other* pods on the same node is a common cause that pod-level
metrics alone can't show.

## Telemetry Pipeline Health

**What it is:** collapsed section (5 panels) covering the observability
pipeline itself — Collector throughput, dropped/refused spans and metric
points, export failures by exporter.

**Why it exists:** every panel above this one *assumes* telemetry is flowing
correctly. This section is what you check when that assumption might be
false — when panels are empty not because the app is idle, but because data
never arrived.

**How to investigate further:** this is the first place to look — not the
last — whenever multiple unrelated panels are simultaneously empty. A spike
in `otelcol_exporter_send_failed_*` on one of the two split Prometheus
exporters tells you whether it's application metrics or spanmetrics failing
(see `ARCHITECTURE.md`'s note on why they're split). See also
`DEVELOPER-GUIDE.md` §5 for the specific known causes already documented for
this stack.
