# Developer Guide — Using This Stack to Watch Your Own App

This is the practical companion to `ARCHITECTURE.md` (how the pieces are wired)
and `MANIFESTS.md` (what each YAML creates). This one is for: *I ship code to
this cluster, something feels slow or broken, how do I find out why in the
next five minutes.*

---

## 1. Trace ID / Span ID — what they actually are

Every time a request enters your app (HTTP call hits the gateway), the
OpenTelemetry Java agent — auto-injected via the annotation in
`instrumentation/otel-operator/instrumentation.yaml`, no code change needed —
starts a **trace**.

- **Trace ID**: a 32-character hex string (128 bits) that identifies *one
  end-to-end request*, from the moment it hits your gateway through every
  downstream call it makes (DB query, another service, a cache lookup).
  Example: `4bf92f3577b34da6a3ce929d0e0e4736`. Every span that belongs to the
  same request shares this same trace ID.

- **Span**: one unit of work inside that trace — "handled this HTTP request,"
  "ran this SQL query," "called this downstream service." Each span records
  its own start time, duration, status (ok/error), and attributes
  (`http.route`, `http.status_code`, `db.statement`, `service.name`, …).

- **Span ID**: a 16-character hex string (64 bits) identifying *one specific
  span* within a trace. Example: `00f067aa0ba902b7`.

- **Parent span ID**: how spans link into a tree. The root span (the one that
  started the trace, e.g. "handle POST /orders") has no parent. Every span it
  triggers (a DB call, a call to another service) records the root span's ID
  as its parent, and so on recursively. Tempo reconstructs this tree and draws
  it as a waterfall/flame graph.

- **Propagation**: when your gateway calls another instrumented service, the
  trace ID and the calling span's ID travel with the HTTP request in a
  `traceparent` header (W3C Trace Context — see `propagators: [tracecontext,
  baggage]` in the Instrumentation CR). That's what lets Tempo stitch spans
  from *different pods, different services* into one continuous trace instead
  of separate disconnected fragments.

**Where the trace ID shows up so you can actually use it:**

| Where | How |
|-------|-----|
| A trace in Tempo | It's in the URL when you open a trace, and shown at the top of the trace view |
| An exemplar on a Prometheus graph | Hover the little diamond marker on a histogram/latency panel — the tooltip shows the trace ID and a "View trace" link |
| A log line in Loki | Structured metadata field `trace_id` on every log line the app emitted during that request (this only works because `allow_structured_metadata: true` is set in `04-loki.yaml` — see `ARCHITECTURE.md`) |
| Manually, for testing | You can force a known trace ID by sending your own `traceparent` header: `curl -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' ...` |

---

## 2. Log in and pick the right dashboard

`https://apm.devopslabs.tech` (or `http://<node-ip>:30300` fallback) —
`admin` / the password in `Secret/grafana-admin`.

Use **`Exora_G360_SRE_API_Dashboard_v10.json`** for day-to-day watching — it's
tuned for this specific gateway (correct label names; see
`V10-DIAGNOSTICS-AND-CONFIG-FIXES.md` for the bug history). It isn't
auto-provisioned: **Dashboards → New → Import → Upload JSON file**. The 10
starter dashboards, sorted into topic folders — APM, Infrastructure, Logs,
Tracing, Database, Platform (`spring-boot.json`,
`http-requests.json`, `jvm.json`, …) are generic fallbacks with no per-service
filter — fine with one app instrumented, but they'll blend multiple services
together if a second one gets added later.

---

## 3. Finding a slow API call and tracing it to the root cause

### Step 1 — Confirm it's slow, and for which route

Look at a latency panel broken out by `http_route` (the "Requests by route" /
"Latency percentiles" panels use `duration_milliseconds_bucket`, produced by
the Collector's `spanmetrics` connector from real trace data — see
`05-otel-collector.yaml`). Note the time window where p95/p99 spiked and which
route it's on.

```promql
histogram_quantile(0.95,
  sum by (le, http_route) (rate(duration_milliseconds_bucket[5m])))
```

### Step 2 — Get one concrete trace ID from that window

Three ways, in order of convenience:

1. **Exemplar click** — hover the latency panel, click an exemplar dot →
   opens that exact slow request's trace. (If no dots appear, the panel's
   query needs "Exemplars" toggled on in edit mode — the starter dashboards
   don't save this setting.)
2. **TraceQL search directly** — Explore → Tempo datasource:
   ```
   { resource.service.name = "Exora-G360_Dev_API_Gateway" && span.http.route = "/your/route" && duration > 1s }
   ```
   Set the time range to the window you identified in Step 1.
3. **From an error log** — Explore → Loki:
   ```
   {service_name="Exora-G360_Dev_API_Gateway"} |= "ERROR"
   ```
   Click the `trace_id` field on a matching line (it's a clickable derived
   field → jumps straight to Tempo).

### Step 3 — Read the trace waterfall

Open the trace. You'll see a tree of spans, each drawn as a bar proportional
to its duration. What to look for:

- **The widest bar** is where the time actually went. If it's a leaf span
  (e.g. a DB call, `db.statement` attribute visible), the delay is in that
  downstream call, not your app's own logic.
- **A gap between a parent span starting and its child span starting** (empty
  space before the child bar begins) usually means queueing — thread pool
  exhaustion, connection pool wait, GC pause — rather than the child call
  itself being slow. Cross-check JVM GC pause / heap panels for that exact
  timestamp.
- **A span marked red/error** — click it for the `exception.message` /
  `exception.stacktrace` attributes the agent captured automatically.
- **Which service owns the slow span** — if it's not your gateway
  (`service.name` differs), the problem is downstream; use the Node Graph tab
  (service map) to see that service's current error/latency rate independent
  of this one trace.

### Step 4 — Get the logs for that exact request

Click the slow/red span → **"Logs for this span"** in the side panel (wired
via `tracesToLogsV2` in `10-grafana-datasources.yaml`). This opens Loki
pre-filtered to that trace's `trace_id`, ±1h window — no manual log grepping
across every pod needed.

### Step 5 — Confirm scope: is this one request or a pattern?

Back in Explore, run the same TraceQL query without the specific trace,
widened to the last hour, to see how many requests hit the same slow path:

```
{ resource.service.name = "Exora-G360_Dev_API_Gateway" && span.http.route = "/your/route" && duration > 1s }
```

If it's one outlier, it's probably transient (GC pause, a cold cache). If it's
consistent, check the JVM dashboard for heap/GC trends and the Node Graph for
a downstream service degrading generally rather than chasing individual
traces.

---

## 4. Quick reference — query snippets

**PromQL** — p99 latency for one route:
```promql
histogram_quantile(0.99, sum by (le) (rate(duration_milliseconds_bucket{http_route="/orders"}[5m])))
```

**PromQL** — error rate for your service:
```promql
sum(rate(calls_total{service_name="Exora-G360_Dev_API_Gateway", status_code="STATUS_CODE_ERROR"}[5m]))
```

**TraceQL** — slow error traces on a route:
```
{ resource.service.name = "Exora-G360_Dev_API_Gateway" && span.http.route = "/orders" && status = error }
```

**LogQL** — all logs for one trace:
```
{service_name="Exora-G360_Dev_API_Gateway"} | trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
```

---

## 5. Things that can quietly make this not work

- **No exemplar dots on a panel** → toggle "Exemplars" on in that panel's
  query editor; it isn't saved in the starter dashboard JSON.
- **A trace you expect isn't there** → check the "OpenTelemetry Collector"
  dashboard's "Spans exported vs refused/s" panel. Batches are capped at 512
  items (`05-otel-collector.yaml`) specifically so one bad sample doesn't
  silently swallow a large batch, but refusals still happen — this panel
  shows if/when.
- **A metric panel is empty on `$__rate_interval` but has data on
  `$__range`** → shouldn't happen anymore (the datasource's `timeInterval:
  "60s"` fix in `10-grafana-datasources.yaml` addressed this), but if it
  recurs, that's the first thing to check.
- **Everything for "your" service looks mixed with another team's numbers** →
  the generic starter dashboards have no `$service_name` filter; use the
  Exora-specific dashboard, or add `service_name="..."` to the query
  yourself in Explore.
