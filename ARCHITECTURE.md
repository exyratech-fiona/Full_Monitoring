# Observability Stack — Architecture & File-by-File Reference

Namespace: `monitoring`. Helm-free, plain Kubernetes YAML, applied in numeric order.

---

## 1. The big picture — how data gets from your app to Grafana

```
                         ┌──────────────────────────────────────────────┐
                         │  Spring Boot app pod (any namespace)         │
                         │  ┌────────────────────────────────────────┐  │
                         │  │ JVM + OpenTelemetry Java agent         │  │
                         │  │ (injected by instrument.sh OR the      │  │
                         │  │  OTel Operator — no image change)      │  │
                         │  └────────────────────────────────────────┘  │
                         └───────────────────┬──────────────────────────┘
                                             │  PUSH  OTLP/gRPC :4317
                                             │  traces + metrics  (logs = none)
                                             ▼
   ┌──────────────────────────────────────────────────────────────────────────┐
   │  otel-collector.monitoring:4317 / :4318                                  │
   │  receivers: otlp                                                         │
   │  processors: memory_limiter → k8sattributes → batch                      │
   │  connector: spanmetrics (traces ⇒ RED metrics)                           │
   └───────┬──────────────────────┬───────────────────────┬───────────────────┘
           │ PUSH OTLP/gRPC       │ PUSH OTLP/HTTP        │ PUSH OTLP/HTTP
           │ tempo:4317           │ prometheus:9090       │ loki:3100
           ▼                      │ /api/v1/otlp/v1/metrics   /otlp/v1/logs
   ┌───────────────┐              │                       ▼
   │  TEMPO :3200  │              │              ┌──────────────────┐
   │  traces → PVC │              │              │  LOKI :3100      │
   │               │              │              │  logs → PVC      │
   │ metrics-      │              │              └────────┬─────────┘
   │ generator     │              │                       │
   └───────┬───────┘              │                       │
           │ PUSH remote_write    │                       │
           │ /api/v1/write        │                       │
           │ (+ exemplars)        │                       │
           ▼                      ▼                       │
   ┌──────────────────────────────────────────────┐       │
   │  PROMETHEUS :9090   (TSDB → PVC, 15d)        │       │
   │                                              │       │
   │  ◄── PULL scrapes every 15s:                 │       │
   │      • otel-collector:8888  (self metrics)   │       │
   │      • node-exporter:9100   (via k8s SD)     │       │
   │      • kube-state-metrics:8080               │       │
   │      • postgres-exporter:9187                │       │
   │      • blackbox-exporter:9115 (/probe)       │       │
   │      • kubelet / cAdvisor / apiserver        │       │
   │                                              │       │
   │  ── evaluates rules → PUSH alerts ──┐        │       │
   └──────────────────────────────────────┼───────┘       │
                                          ▼               │
                            ┌───────────────────────┐     │
                            │ ALERTMANAGER :9093    │     │
                            │ dedupe/group/route →  │     │
                            │ webhook (placeholder) │     │
                            └───────────────────────┘     │
                                                          │
   ┌──────────────────────────────────────────────────────┴───────────────────┐
   │  GRAFANA :3000  (NodePort 30300 / Ingress)                               │
   │  PULLS on demand from all three datasources (server-side proxy):         │
   │    Prometheus http://prometheus:9090   Tempo http://tempo:3200           │
   │    Loki       http://loki:3100                                           │
   └──────────────────────────────────────────────────────────────────────────┘
```

### The one-line rule

**Everything upstream of Prometheus/Tempo/Loki is PUSH. Everything Prometheus
collects from exporters is PULL. Grafana is always PULL.**

### Step-by-step

| # | Hop | Direction | Protocol / endpoint |
|---|-----|-----------|---------------------|
| 1 | App JVM → Collector | push | OTLP gRPC `otel-collector.monitoring.svc:4317` |
| 2 | Collector → Tempo | push | OTLP gRPC `tempo:4317` |
| 3 | Collector → Prometheus | push | OTLP HTTP `http://prometheus:9090/api/v1/otlp/v1/metrics` |
| 4 | Collector → Loki | push | OTLP HTTP `http://loki:3100/otlp/v1/logs` |
| 5 | Tempo metrics-generator → Prometheus | push | remote-write `http://prometheus:9090/api/v1/write` |
| 6 | Prometheus → exporters | pull | HTTP `/metrics` scrape every 15 s |
| 7 | Prometheus → Alertmanager | push | HTTP `alertmanager:9093` |
| 8 | Grafana → Prometheus / Tempo / Loki | pull | HTTP query at dashboard render time |

### Three telemetry pillars — where each one is born and dies

**Metrics** have three independent sources that all land in the same Prometheus TSDB:

1. **App metrics** (JVM heap, GC, HTTP server, JDBC) — OTel agent → Collector → OTLP push.
2. **Derived RED metrics** — the Collector's `spanmetrics` connector turns *traces*
   into `calls_total` and `duration_milliseconds_bucket`, then feeds them back into
   its own metrics pipeline → OTLP push. Exemplars are enabled, which is what makes
   a metric point clickable through to a trace.
3. **Infrastructure metrics** — node-exporter, kube-state-metrics, cAdvisor, kubelet,
   apiserver, postgres-exporter, blackbox-exporter — all **scraped** by Prometheus.

Plus a fourth trickle: Tempo's own metrics-generator (service graphs + span metrics)
remote-writes into Prometheus with `source="tempo"`.

**Traces** — OTel agent → Collector → Tempo → local PVC blocks (7 d retention).

**Logs** — Collector → Loki over OTLP → local PVC chunks (7 d retention).
⚠️ See "Known gaps" below: the agent is currently configured with
`OTEL_LOGS_EXPORTER=none`, so this pipeline is wired but idle.

### Correlation — the reason all three live in one Grafana

| Jump | Mechanism | Configured in |
|------|-----------|---------------|
| Metrics → Traces | Prometheus exemplars carry `trace_id`; `exemplarTraceIdDestinations` points at the Tempo datasource | `10-grafana-datasources.yaml` |
| Traces → Logs | `tracesToLogsV2` opens Loki filtered by trace ID | `10-grafana-datasources.yaml` |
| Traces → Metrics | `tracesToMetrics` runs `sum(rate(calls_total{…}[5m]))` against Prometheus; `serviceMap` draws the node graph from Tempo's generated metrics | `10-grafana-datasources.yaml` |
| Logs → Traces | Loki `derivedFields` matches the `trace_id` structured-metadata label and links to Tempo | `10-grafana-datasources.yaml` |

The glue is `promote_resource_attributes` in `01-prometheus.yaml` — it turns OTLP
resource attributes (`service.name`, `k8s.pod.name`, …) into real Prometheus labels
(`service_name`, `k8s_pod_name`), so the same identity exists in all three stores.

---

## 2. File-by-file reference

For each file: what it creates, what it does, and **where it pushes data / who pulls from it**.

---

### `00-namespace.yaml`
**Creates:** `Namespace/monitoring`

Labels it `app.kubernetes.io/part-of: observability` and sets Pod Security Admission
to `privileged` (enforce/audit/warn). The `privileged` level is required because
node-exporter runs with `hostNetwork`, `hostPID` and hostPath mounts of `/proc`,
`/sys`, `/`, and several components run root init containers to `chown` their PVCs.

**Data flow:** none — it is the boundary every other object lives in.

---

### `01-prometheus.yaml`
**Creates:** `ServiceAccount/prometheus`, `ConfigMap/prometheus-config`,
`Deployment/prometheus`, `Service/prometheus:9090`

The central metrics store. It is both a **receiver** (push) and a **scraper** (pull).

**Container flags that matter:**

| Flag | Effect |
|------|--------|
| `--storage.tsdb.retention.time=15d` | 15-day metric retention on the `prometheus-data` PVC |
| `--web.enable-remote-write-receiver` | Opens `POST /api/v1/write` — **Tempo's metrics-generator writes here** |
| `--enable-feature=otlp-write-receiver` | Opens `POST /api/v1/otlp/v1/metrics` — **the OTel Collector pushes here** |
| `--web.enable-lifecycle` | Allows `POST /-/reload` to hot-reload config after a ConfigMap change |

**Global config:** 15 s scrape + 15 s rule evaluation; every series gets external
labels `cluster="kubernetes"`, `environment="dev"`.

**`otlp.promote_resource_attributes`:** promotes OTLP resource attributes to
Prometheus labels. Includes `service.name`, `service.instance.id`,
`service.namespace`, `deployment.environment.name` (required by the Grafana OTel
dashboards) plus the full `k8s.*` set. Without this the alerts in file 09 that
group `by (service_name)` would have nothing to group on.

**Scrape jobs — everything Prometheus PULLS:**

| Job | Target | What it collects |
|-----|--------|------------------|
| `prometheus` | `localhost:9090` | self-monitoring |
| `otel-collector-internal` | `otel-collector:8888` | Collector throughput/drop/queue metrics. Note: **8889 is deliberately NOT scraped** — app metrics now arrive via OTLP push instead |
| `node-exporter` | k8s `endpoints` SD in `monitoring`, filtered to the node-exporter service + `metrics` port | host CPU/mem/disk/net. Relabels `instance` and `node` to the node name |
| `kube-state-metrics` | `kube-state-metrics:8080` | K8s object state (pod phase, restarts, waiting reason, node conditions) |
| `postgres-exporter-db1` through `postgres-exporter-db6` | `postgres-exporter-dbN:9187` | `pg_up`, connections, transactions, with a `database` label |
| `blackbox-http` | `/probe?module=http_2xx&target=…` proxied through `blackbox-exporter:9115` | synthetic probes of `http://rego-app-server.default…:8080/actuator/health` and `/actuator/prometheus`. The relabel chain moves `__address__` into `__param_target`, keeps it as `instance`, then rewrites `__address__` to the exporter |
| `blackbox-exporter` | `blackbox-exporter:9115` | the exporter's own health |
| `kubernetes-cadvisor` | `node` SD → `kubernetes.default.svc:443/api/v1/nodes/$node/proxy/metrics/cadvisor` | per-container CPU/memory (`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`) |
| `kubernetes-kubelet` | same, `/proxy/metrics` | kubelet runtime metrics |
| `kubernetes-apiservers` | `endpoints` SD kept to `default;kubernetes;https` | API server latency/error metrics |

The last three authenticate with the pod's ServiceAccount token
(`/var/run/secrets/.../token`) and the cluster CA, with `insecure_skip_verify: true`.

**Alerting:** static Alertmanager target `alertmanager:9093`.
**Rules:** loads `/etc/prometheus/rules/*.yml` — mounted from `ConfigMap/prometheus-rules` (file 09).

**Where it pushes:** firing alerts → Alertmanager (file 08).
**Who pulls from it:** Grafana (file 10 datasource), and Tempo's `tracesToMetrics`.

**Pod details:** runs as uid 65534 (nobody), `Recreate` strategy (single writer to a
RWO volume), a root `busybox` init container `chown`s `/prometheus`, requests
250m CPU / 512Mi and the file specifies a 2Gi memory limit.

> ⚠️ **2026-09-16 incident: OOMKilled 131 times over 16h.** The pod restarted in
> a loop, exit code 137, each attempt dying ~6 minutes into WAL replay before it
> could finish and checkpoint. Root cause: the WAL had grown to ~4089 segments
> (normal is a couple hundred) because repeated OOM kills never let a replay
> finish long enough to checkpoint/truncate it — a self-reinforcing spiral where
> every restart had a bigger backlog to replay than the last one had memory for.
> Readiness/liveness probes were **not** the cause (liveness `initialDelaySeconds`
> was 600s, far past the 6-minute death point); node memory pressure (node was at
> ~90% before this pod even ran) meant there was little headroom to begin with.
> **Live-patched** via `kubectl -n monitoring set resources deployment/prometheus
> -c prometheus --limits=memory=6Gi`, and this file's `limits.memory` has been
> updated to `6Gi` to match, so `kubectl apply -f 01-prometheus.yaml` no longer
> reverts it. (First patch attempt silently didn't stick — a re-apply
> immediately after confirmed the second attempt took effect; if this happens
> again, check for something re-applying the old manifest, e.g. a GitOps
> controller or cron.) Re-check node headroom before raising it further
> (`dolsb001` had only ~8-10Gi free at the time). Also worth confirming after
> recovery: how often WAL checkpointing has actually been succeeding, and
> whether `--storage.tsdb.wal-compression` is worth enabling.
>
> Separately, the **live liveness/readiness probe `initialDelaySeconds` values
> observed on the running Deployment (60s / 600s) do not match this file's
> current values (15s / 30s)** — someone likely `kubectl edit`ed the live
> Deployment at some point without updating this manifest. Reconcile one way or
> the other; right now `kubectl apply -f 01-prometheus.yaml` would silently
> tighten the probes back down.

---

### `02-grafana.yaml`
**Creates:** `ServiceAccount/grafana`, `Secret/grafana-admin`,
`Deployment/grafana`, `Service/grafana` (**NodePort 30300**)

The single query UI. Grafana **never receives** telemetry — it pulls from all three
backends on demand when a panel renders, using `access: proxy` (the Grafana server
makes the request, not the browser).

**Key env:**
- `GF_SECURITY_ADMIN_USER` / `_PASSWORD` from `Secret/grafana-admin`
  (currently `admin` / `ChangeMe_Admin123!` — **change this**).
- `GF_USERS_ALLOW_SIGN_UP=false`
- `GF_FEATURE_TOGGLES_ENABLE=traceToMetrics,traceqlEditor` — required for the
  Traces→Metrics jump and the TraceQL query editor.
- `GF_SERVER_DOMAIN=apm.devopslabs.tech` / `GF_SERVER_ROOT_URL=https://apm.devopslabs.tech/`
  — **added 2026-08-12.** Behind the centralised nginx at `apm.devopslabs.tech`,
  Grafana's default `%(domain)s` resolved to `localhost`, which breaks Grafana
  Live (the websocket `Origin` header is checked against `root_url`; a mismatch
  silently refuses the socket, so live/streaming panels stop updating), absolute
  links in alert notifications, and any future OAuth `redirect_uri`. The
  protocol is **hardcoded to `https`**, not `%(protocol)s` — Grafana's own
  listener is still plain HTTP (TLS terminates at nginx); left as
  `%(protocol)s` it would resolve to `http://apm.devopslabs.tech/` while the
  browser sends `Origin: https://apm.devopslabs.tech`.
- `GF_SECURITY_COOKIE_SECURE=false` — held at `false` until the HTTPS vhost is
  confirmed working end to end (see `nginx-apm.devopslabs.tech.conf`, Stage 1 vs
  Stage 2 below); `true` would also block logging in via the NodePort fallback.
- `GF_SERVER_ENFORCE_DOMAIN=false` — nginx terminates the connection and its
  `X-Forwarded-*` headers are trusted so Grafana logs the real client IP.

**External access path (not a k8s manifest — `nginx-apm.devopslabs.tech.conf` in
this repo root):** browser → `https://apm.devopslabs.tech` → an external nginx
box → `http://192.168.0.162:30300` (this Service's NodePort on node `dolsb001`,
with `dola001`/`dolkw001` as `backup` upstreams) → Grafana. WebSocket upgrade
headers and `proxy_buffering off` are required there for Grafana Live and
streaming panels. **Currently Stage 1** (plain HTTP on nginx's `:80`, no TLS
cert issued yet — a stale cert reference previously made `nginx reload` fail
silently while serving the old config). Stage 2 (`certbot --nginx -d
apm.devopslabs.tech`) will add the `:443` vhost and the http→https redirect;
`GF_SECURITY_COOKIE_SECURE` should flip to `true` once that lands.

**Mounts (this is how provisioning works):**

| Mount path | From ConfigMap | Purpose |
|------------|----------------|---------|
| `/etc/grafana/provisioning/datasources` | `grafana-datasources` (file 10) | auto-creates the 3 datasources at boot |
| `/etc/grafana/provisioning/dashboards` | `grafana-dashboard-provider` (file 11) | tells Grafana to watch a directory |
| `/var/lib/grafana/dashboards` | `grafana-dashboards` (file 11) | the 10 dashboard JSONs |
| `/var/lib/grafana` | PVC `grafana-data` | SQLite DB: users, prefs, UI-created dashboards |

**Exposure:** `type: NodePort`, `nodePort: 30300` → reachable at
`http://<any-node-ip>:30300`, intended to sit behind an external nginx. Also has an
Ingress in file 16. Runs as uid 472 with a root init container to `chown` the PVC.

---

### `03-tempo.yaml`
**Creates:** `ConfigMap/tempo-config`, `Deployment/tempo`,
`Service/tempo` (3200 HTTP, 4317 OTLP gRPC, 4318 OTLP HTTP)

Trace store, monolithic single-binary mode.

**Receives (push):** OTLP on `0.0.0.0:4317` (gRPC) and `:4318` (HTTP) — the Collector's
`otlp/tempo` exporter writes here. The gRPC/HTTP ports are exposed so an app *could*
bypass the Collector and write directly, but nothing in this stack does.

**Stores:** `backend: local` — WAL at `/var/tempo/wal`, blocks at `/var/tempo/blocks`,
both on the `tempo-data` PVC. Compactor enforces `block_retention: 168h` (7 days).
`ingester.max_block_duration: 5m` so blocks flush and become queryable quickly.

**Pushes:** the **metrics-generator** is the second data producer in this file.
Processors `[service-graphs, span-metrics]` derive metrics from the trace stream and
`remote_write` them to `http://prometheus:9090/api/v1/write` with
`send_exemplars: true`, tagged `source="tempo"`. `service-graphs` is what powers
Grafana's Service Map / node graph; `span-metrics` produces per-span RED-style
metrics from Tempo's own view of the trace stream (separate from, and redundant
with, the Collector's `spanmetrics` connector — see file 05).

> ⚠️ **`local-blocks` was removed 2026-08-11.** It retains every recent span in
> memory so TraceQL metrics queries (`{...} | rate()`) can be served. Nothing on
> the SRE dashboard uses TraceQL metrics — the service graph comes from
> `service-graphs` and RED metrics come from the Collector's `spanmetrics`
> connector — so it was pure memory cost. With `filter_server_spans: false` it
> retained *every* span, pinning Tempo at 100% of its 2Gi limit and making the
> readiness probe time out. If you want TraceQL metrics later, re-add
> `local-blocks` **and** raise Tempo's memory limit at the same time.

**Who pulls from it:** Grafana (Tempo datasource, `http://tempo:3200`).

Runs as uid 10001 with a root `chown` init container.

---

### `04-loki.yaml`
**Creates:** `ConfigMap/loki-config`, `Deployment/loki`, `Service/loki` (3100 HTTP, 9096 gRPC)

Log store, monolithic mode, `auth_enabled: false` (single tenant — no `X-Scope-OrgID` needed).

**Receives (push):** native OTLP at `POST /otlp/v1/logs`. The Collector's
`otlphttp/loki` exporter targets `http://loki:3100/otlp` and the exporter appends
`/v1/logs`.

**Stores:** TSDB index (schema `v13`, 24 h index period) + filesystem chunks under
`/loki` on the `loki-data` PVC. Compactor runs every 10 m with
`retention_enabled: true` / `retention_period: 168h` (7 days).

**Critical setting:** `limits_config.allow_structured_metadata: true`. This is what
lets OTLP log attributes — including `trace_id` — survive as structured metadata
instead of being flattened away. Without it, the Loki→Tempo derived-field jump in
file 10 has nothing to match on.

Ingestion capped at 16 MB/s with a 32 MB burst. `volume_enabled: true` powers the
log-volume histogram in Explore. Analytics reporting is off.

**Who pulls from it:** Grafana (Loki datasource, `http://loki:3100`).

---

### `05-otel-collector.yaml`
**Creates:** `ConfigMap/otel-collector-config`, `Service/otel-collector`
(4317, 4318, 8889, 8888)

**The single ingestion point for all application telemetry — this is the heart of the pipeline.**

**Receivers:** `otlp` on `0.0.0.0:4317` (gRPC) and `0.0.0.0:4318` (HTTP).

**Processors (applied to all three pipelines, in order):**

| Processor | What it does |
|-----------|--------------|
| `memory_limiter` | checks every 5 s; soft-limit 80 % of the container limit, 25 % spike allowance — starts refusing data instead of OOMing |
| `k8sattributes` | calls the K8s API (via `auth_type: serviceAccount`) and enriches every span/metric/log with `k8s.namespace.name`, `k8s.deployment.name`, `k8s.pod.name`, `k8s.pod.uid`, `k8s.node.name`, `k8s.container.name`, plus the `app.kubernetes.io/name` label as `app`. Pod association tries `k8s.pod.ip`, then `k8s.pod.uid`, then falls back to the source IP of the connection |
| `batch` | 5 s timeout, 512-item batches, 512 max |

> ⚠️ **Batch size lowered from 1024/2048 to 512/512.** Prometheus' OTLP receiver
> rejects an entire request on any append error — there is no partial write — so
> a max batch of 2048 was discarding 2048 metric points per single bad sample.
> Smaller batches shrink the blast radius of one poisoned series.

**Connector `spanmetrics`:** this is the piece that makes traces produce metrics.
It sits as an *exporter* on the traces pipeline and a *receiver* on the metrics
pipeline. It emits `calls_total` and a `duration` histogram in ms with explicit
buckets 5 ms → 10 s, dimensioned by `http.request.method`,
`http.response.status_code`, `http.route`, flushed every 15 s, with
**`exemplars.enabled: true`** — the exemplars are what carry `trace_id` into
Prometheus and make metric→trace navigation work.

**Exporters — where the Collector pushes:**

| Exporter | Destination | Signal |
|----------|-------------|--------|
| `otlp/tempo` | `tempo:4317` (gRPC, TLS insecure) | traces |
| `otlphttp/prometheus` | `http://prometheus:9090/api/v1/otlp` → resolves to `/api/v1/otlp/v1/metrics` | application metrics (`http.server.*`, `jvm.*`, `db.client.*`) |
| `otlphttp/prometheus_spanmetrics` | same endpoint, separate exporter instance | connector-derived RED metrics (`calls_total`, `duration_milliseconds_bucket`) |
| `otlphttp/loki` | `http://loki:3100/otlp` → resolves to `/otlp/v1/logs` | logs |

> **Why two exporters to the same URL?** `otelcol_exporter_send_failed_metric_points_total`
> is labelled by exporter name. With one shared exporter, a 400 tells you metrics
> are being dropped but not *which* source poisoned the batch — application
> metrics or connector-derived spanmetrics. Split like this, the Telemetry
> Pipeline Health panel names the culprit at a glance, and a bad spanmetrics
> series can no longer take the application's own metrics down with it.

**Pipelines (now four, not one combined `metrics` pipeline):**
```
traces            : otlp        → [memory_limiter, k8sattributes, batch] → otlp/tempo + spanmetrics
metrics/app       : otlp        → [memory_limiter, k8sattributes, batch] → otlphttp/prometheus
metrics/spanmetrics: spanmetrics → [memory_limiter, batch]               → otlphttp/prometheus_spanmetrics
logs              : otlp        → [memory_limiter, k8sattributes, batch] → otlphttp/loki
```

`metrics/spanmetrics` deliberately **omits `k8sattributes`**. Spanmetrics is
generated in-process by the connector, so there's no client connection for
`k8sattributes` to associate against — its resource attributes were already
enriched in the traces pipeline. Running `k8sattributes` again on connector
output risks rewriting `k8s.pod.name` and collapsing multiple pods onto one
label set, which Prometheus would reject as duplicate samples at the same
timestamp.

**Self-telemetry:** a pull-based Prometheus reader on `0.0.0.0:8888` — scraped by
the `otel-collector-internal` job. Health check extension on `:13133`.

**Service ports:** 4317/4318 for apps, 8888 for internal metrics, and 8889 kept
"for compatibility" — the old `prometheus` exporter port, no longer used now that
metrics go out over OTLP.

> ⚠️ **This file contains no `Deployment` and no `ServiceAccount`.** See "Known gaps".

---

### `06-node-exporter.yaml`
**Creates:** `ServiceAccount/node-exporter`, `DaemonSet/node-exporter`,
headless `Service/node-exporter:9100`

One pod per node (including control-plane — `tolerations: [{operator: Exists}]`
tolerates every taint). Uses `hostNetwork: true`, `hostPID: true` and `hostPort: 9100`,
with read-only hostPath mounts of `/proc`, `/sys` and `/` (the last with
`mountPropagation: HostToContainer`).

Excludes pseudo-filesystems and container-runtime mount points so
`node_filesystem_*` reports real disks only.

**Data flow: PULL only.** It exposes `/metrics` on 9100 and never pushes. Prometheus
finds it through the `endpoints` role service discovery on the headless Service.
Feeds `HighNodeCPU`, `HighNodeMemory`, `HighDiskUsage` and the Nodes dashboard.

---

### `07-kube-state-metrics.yaml`
**Creates:** `ServiceAccount/kube-state-metrics`, `Deployment`,
`Service` (8080 metrics, 8081 telemetry)

Watches the Kubernetes API and turns object **state** into metrics —
`kube_pod_status_phase`, `kube_pod_container_status_restarts_total`,
`kube_pod_container_status_waiting_reason`,
`kube_pod_container_status_last_terminated_reason`, `kube_node_status_condition`,
`kube_namespace_created`.

This is *not* resource usage (that's cAdvisor) — it is desired/observed object state.

**Data flow: PULL only** — Prometheus scrapes `kube-state-metrics:8080` statically.
Its cluster-wide read permissions come from `14-rbac.yaml`. Hardened container:
read-only root FS, no privilege escalation, all capabilities dropped.

Feeds `NodeNotReady`, `PodRestartingFrequently`, `PodCrashLoopBackOff`,
`PodOOMKilled` and the Cluster/Pods dashboards.

---

### `08-alertmanager.yaml`
**Creates:** `ConfigMap/alertmanager-config`, `Deployment/alertmanager`,
`Service/alertmanager:9093`

**Receives (push):** alerts from Prometheus, which posts to `alertmanager:9093`
whenever a rule in file 09 has been firing for its `for:` duration.

**Routing:** groups by `alertname` + `namespace`, waits 30 s before the first
notification (`group_wait`), 5 m between updates to a group (`group_interval`),
re-notifies every 4 h — or every 1 h for `severity="critical"`.

**Inhibition:** a firing `critical` alert suppresses a `warning` with the same
`alertname` + `namespace`, so you get one page instead of two.

**Pushes to:** `receivers: [default]` → `webhook_configs` at
`http://127.0.0.1:5001/` — **a placeholder that goes nowhere.** Replace with a real
Slack / email / PagerDuty integration (a commented `slack_configs` example is in the file).

State (silences, notification log) persists on the `alertmanager-data` PVC.

---

### `09-prometheus-rules.yaml`
**Creates:** `ConfigMap/prometheus-rules` — five rule files, mounted into Prometheus
at `/etc/prometheus/rules/`

Evaluated by Prometheus every 15 s; firing alerts are pushed to Alertmanager.
No data of its own moves.

| Rule file | Alert | Expression basis | Severity |
|-----------|-------|------------------|----------|
| `node.rules.yml` | `HighNodeCPU` | `node_cpu_seconds_total{mode="idle"}` > 85 % used, 5 m | warning |
| | `HighNodeMemory` | `node_memory_MemAvailable_bytes / MemTotal` > 85 %, 5 m | warning |
| | `HighDiskUsage` | `node_filesystem_avail_bytes` > 85 %, excl. tmpfs/overlay/squashfs, 10 m | warning |
| | `NodeNotReady` | `kube_node_status_condition{condition="Ready"} == 0`, 5 m | critical |
| `workload.rules.yml` | `PodRestartingFrequently` | `increase(kube_pod_container_status_restarts_total[15m]) > 3` | warning |
| | `PodCrashLoopBackOff` | `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}`, 2 m | critical |
| | `PodOOMKilled` | `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`, immediate | critical |
| `jvm.rules.yml` | `JVMHeapHigh` | `jvm_memory_used_bytes / jvm_memory_limit_bytes{jvm_memory_type="heap"} > 0.90`, 5 m | warning |
| | `JVMHighGCPause` | mean `jvm_gc_duration_seconds` > 100 ms, 5 m | warning |
| `http.rules.yml` | `HTTP5xxErrors` | `calls_total{status_code="STATUS_CODE_ERROR"}` > 5 % of all calls, 5 m | critical |
| | `HTTPHighLatency` | `histogram_quantile(0.95, duration_milliseconds_bucket)` > 1000 ms, 5 m | warning |
| `postgres.rules.yml` | `PostgreSQLDown` | `pg_up == 0`, 1 m | critical |

The JVM and HTTP rules depend on the OTLP path: `jvm_*` comes from the Java agent,
`calls_total` / `duration_milliseconds_bucket` come from the Collector's
`spanmetrics` connector. Both group `by (service_name)`, which only exists because
`promote_resource_attributes` in file 01 promotes `service.name`.

---

### `10-grafana-datasources.yaml`
**Creates:** `ConfigMap/grafana-datasources` → mounted at
`/etc/grafana/provisioning/datasources/datasources.yaml`

Defines the three datasources with fixed UIDs (`prometheus`, `tempo`, `loki`) —
fixed UIDs are what let the dashboard JSONs and the cross-links reference each other.

| Datasource | URL | Notable config |
|------------|-----|----------------|
| **Prometheus** (default) | `http://prometheus:9090` | `httpMethod: POST`; `timeInterval: "60s"`; `exemplarTraceIdDestinations` maps the `trace_id` exemplar label → Tempo, label "View trace" |
| **Tempo** | `http://tempo:3200` | `tracesToLogsV2` → Loki, ±1 h window, `filterByTraceID: true`, maps `service.name`→`service_name`; `tracesToMetrics` → Prometheus with `sum(rate(calls_total{$__tags}[5m]))`; `serviceMap` → Prometheus (reads Tempo's remote-written service-graph metrics); `nodeGraph` enabled; span bar shows `http.status_code` |
| **Loki** | `http://loki:3100` | `derivedFields`: matcher type `label`, regex `trace_id` → Tempo datasource, "View trace" |

**Data flow:** Grafana pulls from all three. This file creates no data path of its
own — it creates the *navigation* paths between the three stores.

> ⚠️ **`timeInterval: "60s"` added 2026-08-11 — required, not cosmetic.** Grafana
> derives `$__rate_interval` as `max($__interval + timeInterval, 4 * timeInterval)`.
> Without it, Grafana assumes a 15 s scrape and produces a ~1 m rate window. The
> OTel Java agent pushes metrics every 60 s, so a 1 m window rarely contains two
> samples and `rate()` / `histogram_quantile()` return nothing — verified:
> `rate(...[1m])` → 0 series, `rate(...[2m])` → 8 series. This is why every
> `$__rate_interval` panel was empty while every `$__range` panel had data.

---

### `11-grafana-dashboards.yaml`
**Creates:** two ConfigMaps.

1. **`grafana-dashboard-provider`** → `/etc/grafana/provisioning/dashboards/provider.yaml`.
   Tells Grafana: load every `*.json` from `/var/lib/grafana/dashboards`, rescan
   every 30 s, allow UI edits.
2. **`grafana-dashboards`** → `/var/lib/grafana/dashboards`, one key per dashboard JSON.

> **2026-09-16: switched from one flat "Observability" folder to folder-per-topic.**
> `foldersFromFilesStructure: true` in the provider ConfigMap now derives each
> dashboard's Grafana folder from the *directory* it's mounted into, not from a
> fixed `folder:` value. That directory structure comes from `items:` on the
> `dashboards` volume in `02-grafana.yaml`, which remaps each ConfigMap key to
> `<Folder>/<file>.json`. The `grafana-dashboards` ConfigMap keys themselves are
> unchanged — only where they land on disk (and therefore which Grafana folder
> they show up in) changed.

Ten starter dashboards, all pinned to the datasource UIDs from file 10:

| Key | Folder | Dashboard | Primary data source of truth |
|-----|--------|-----------|------------------------------|
| `k8s-cluster.json` | Infrastructure | Kubernetes Cluster | kube-state-metrics + cAdvisor |
| `nodes.json` | Infrastructure | Nodes | node-exporter |
| `pods.json` | Infrastructure | Pods | cAdvisor + kube-state-metrics |
| `jvm.json` | APM | JVM | OTel Java agent → Collector → OTLP |
| `spring-boot.json` | APM | Spring Boot | OTel Java agent + spanmetrics |
| `http-requests.json` | APM | HTTP Requests | spanmetrics (`calls_total`, `duration_milliseconds_bucket`) |
| `postgresql.json` | Database | PostgreSQL — title now flags **(inactive)** | postgres-exporter — dead, see file 12 |
| `opentelemetry.json` | Platform | OTel Collector | Collector self-metrics from `:8888` |
| `tempo.json` | Tracing | Tempo | Tempo self-metrics |
| `loki.json` | Logs | Loki | Loki self-metrics |

`Exora_G360_SRE_API_Dashboard_v10.json` (repo root, manually imported — see the
"Not YAML" table in `MANIFESTS.md`) is deliberately **not** part of this
folder-per-topic remap; it's a single-window trace↔log↔metric correlation tool
and splitting its rows apart would break that. File it under the **APM** folder
manually at import time (Import dialog → Folder picker) to sit alongside
`jvm.json`/`spring-boot.json`/`http-requests.json`.

**Data flow:** none — these only define queries Grafana runs against Prometheus/Tempo/Loki.

---

### `12-postgres-exporter.yaml`
**Creates:** one Secret, Deployment, and Service per PostgreSQL database; each exporter exposes metrics on `:9187`

> ⚠️ **Scaled to zero 2026-08-11 — this exporter has never worked and should not
> simply be scaled back up.** Its `DATA_SOURCE_NAME` points at
> `postgres.default.svc.cluster.local`, which does not resolve — there is **no
> PostgreSQL anywhere in this cluster**. The Exora G360 gateway (the app this
> whole stack instruments) runs on **MySQL**, confirmed from Tempo spans
> (`db.system=mysql`, `db.name=g360_dev_api_gateway`). Left running, it leaked
> memory on every failed connection attempt and was OOMKilled 57 times over 28
> days, permanently `NotReady` — and because the rolling update could never
> complete (the new pod never became Ready), two ReplicaSets stayed alive
> simultaneously. Raising its memory limit would only have slowed the leak.
>
> **To actually get database metrics:** deploy `prom/mysqld-exporter` instead,
> pointed at the real MySQL instance, and add a corresponding `mysqld-exporter`
> scrape job to `01-prometheus.yaml`. Until then, `pg_up`, the `PostgreSQLDown`
> alert (file 09), and the `postgresql.json` dashboard (file 11) have no data
> and should be treated as dead / for-reference-only.

**Data flow (when it *was* attempted):** exporter → PostgreSQL (pull, SQL),
Prometheus → exporter (pull, HTTP). Never pushes.

Hardened container: read-only root FS, all capabilities dropped, uid 65534.

---

### `13-blackbox-exporter.yaml`
**Creates:** `ConfigMap/blackbox-exporter-config`, `Deployment`, `Service:9115`

Synthetic/black-box probing — the only component that tests your app from the
*outside*, the way a user would.

**Modules defined:** `http_2xx` (GET, 5 s timeout, requires HTTP 200, follows
redirects, IPv4 preferred), `http_post_2xx`, `tcp_connect`.

**Data flow — a three-way handshake:**
1. Prometheus scrapes `blackbox-exporter:9115/probe?module=http_2xx&target=<url>`
2. The exporter makes the actual HTTP request to `<url>`
3. It returns `probe_success`, `probe_duration_seconds`, `probe_http_status_code`, TLS
   expiry, etc. in the scrape response

Targets are declared in `01-prometheus.yaml` job `blackbox-http`:
`rego-app-server.default.svc.cluster.local:8080/actuator/health` and
`/actuator/prometheus`.

---

### `14-rbac.yaml`
**Creates:** three `ClusterRole` + `ClusterRoleBinding` pairs. ServiceAccounts live
in each component's own file so ordering works.

| ClusterRole | Bound to | Grants |
|-------------|----------|--------|
| `monitoring-prometheus` | `monitoring/prometheus` | get/list/watch on nodes, `nodes/proxy`, `nodes/metrics`, services, endpoints, pods, ingresses; get on configmaps; nonResourceURLs `/metrics` and `/metrics/cadvisor` — this is what makes `kubernetes_sd_configs` and the cAdvisor/kubelet proxy scrapes work |
| `monitoring-otel-collector` | `monitoring/otel-collector` | get/list/watch on pods, namespaces, nodes, endpoints, replicasets, deployments, daemonsets, statefulsets — required by the `k8sattributes` processor to resolve a pod IP into K8s metadata |
| `monitoring-kube-state-metrics` | `monitoring/kube-state-metrics` | list/watch across core, apps, batch, autoscaling, policy, certificates, storage, admissionregistration, networking, coordination; create on tokenreviews/subjectaccessreviews |

**Data flow:** none directly — but without these, the k8s SD scrapes, the
k8sattributes enrichment, and kube-state-metrics all fail.

---

### `15-pvc.yaml`
**Creates:** five `PersistentVolumeClaim`s, all `ReadWriteOnce`, all relying on the
cluster's **default StorageClass** (`storageClassName` is commented out).

| PVC | Size | Consumer | Holds |
|-----|------|----------|-------|
| `prometheus-data` | 20 Gi | Prometheus | TSDB, 15 d |
| `grafana-data` | 5 Gi | Grafana | SQLite: users, prefs, UI dashboards |
| `tempo-data` | 15 Gi | Tempo | trace WAL + blocks + generator WAL, 7 d |
| `loki-data` | 15 Gi | Loki | log chunks + TSDB index, 7 d |
| `alertmanager-data` | 2 Gi | Alertmanager | silences + notification log |

RWO is why every consumer uses `strategy: Recreate` — the old pod must release the
volume before the new one can attach.

---

### `16-ingress.yaml`
**Creates:** three NGINX `Ingress` objects (optional).

| Host | → Service | Auth |
|------|-----------|------|
| `grafana.example.com` | `grafana:3000` | Grafana's own login |
| `prometheus.example.com` | `prometheus:9090` | nginx basic-auth via `Secret/monitoring-basic-auth` |
| `alertmanager.example.com` | `alertmanager:9093` | nginx basic-auth, same secret |

Prometheus and Alertmanager have no built-in authentication, hence the basic-auth
annotations. Create the secret with `htpasswd -c auth admin` then
`kubectl -n monitoring create secret generic monitoring-basic-auth --from-file=auth`.
No TLS block yet — add one referencing a cert-manager Secret. Hosts must be replaced
with real DNS.

**Note:** Grafana is *also* exposed via NodePort 30300 in file 02, so you can skip
this file entirely if an external nginx fronts the node port.

---

## 3. `instrumentation/` — how the app starts producing telemetry

This is step 0 of the whole pipeline: getting the OpenTelemetry Java agent into your
JVM without touching app code or rebuilding an image. Two mutually exclusive
approaches are provided.

### Approach A — kubectl patch scripts (no cluster prerequisites)

#### `instrumentation/instrument.sh`
`./instrument.sh <namespace> <deployment> [service-name] [environment]`

Strategic-merge-patches one Deployment to add:
- an **init container** `otel-agent` from
  `ghcr.io/…/autoinstrumentation-java:2.11.0` that runs
  `cp /javaagent.jar /otel/opentelemetry-javaagent.jar`
- an **emptyDir** volume `otel-agent`, mounted at `/otel` in both containers
- **`JAVA_TOOL_OPTIONS`** on the app container — the JVM reads this env var at
  startup and loads the agent, which is why no code change is needed

The `JAVA_TOOL_OPTIONS` value sets:
`-javaagent:/otel/opentelemetry-javaagent.jar`, `otel.service.name`,
`otel.resource.attributes=deployment.environment=…`,
`otel.exporter.otlp.endpoint=http://otel-collector.monitoring.svc.cluster.local:4317`,
`protocol=grpc`, `traces.exporter=otlp`, `metrics.exporter=otlp`,
**`logs.exporter=none`**, plus JDBC and Spring WebMVC instrumentation enabled.

Guard: refuses to run if `JAVA_TOOL_OPTIONS` already exists (it might hold `-Xmx`),
exits 2 and asks you to merge manually. Then waits on `rollout status`.

#### `instrumentation/instrument-all-be.sh`
Bulk version. Lists every Deployment in every namespace, keeps those matching
`NAME_REGEX` (default `be$` — your backends end in "be", frontends in "fe"), skips
system namespaces (`kube-*`, `monitoring`, `ingress-nginx`, `cert-manager`,
`local-path-storage`). **Dry-run by default**; `--apply` actually patches.
Derives `deployment.environment` from the namespace name (matches
`dev|sit|demo|uat|preprod|prod|staging`, else uses the namespace). Skips deployments
already carrying the `otel-agent` init container or an existing `JAVA_TOOL_OPTIONS`.

#### `instrumentation/deinstrument.sh`
`./deinstrument.sh <namespace> <deployment> [--full]` — removes `JAVA_TOOL_OPTIONS`
(the JVM then simply stops loading the agent). `--full` also removes the init
container via a JSON-patch guarded by a `test` op on `initContainers/0/name`.

### Approach B — OpenTelemetry Operator (declarative, survives image updates)

#### `instrumentation/otel-operator/instrumentation.yaml`
An `Instrumentation` CR named `monitoring/rego-instrumentation`: exporter endpoint
`http://otel-collector.monitoring.svc.cluster.local:4317`, propagators
`tracecontext` + `baggage`, sampler `parentbased_traceidratio` at `1.0` (100 % —
lower for high-traffic prod), and the same Java env as the scripts
(`OTEL_LOGS_EXPORTER=none`).

Workloads opt in with a single pod annotation:
```
instrumentation.opentelemetry.io/inject-java: "monitoring/rego-instrumentation"
```
and the operator's mutating webhook injects the agent on the next rollout.
`service.name` is auto-derived per workload.

#### `instrumentation/otel-operator/README.md`
Install order: cert-manager → OpenTelemetry Operator → the Instrumentation CR.
Documents a real risk: **both use admission webhooks, and this cluster has shown a
webhook reachability problem** (`context deadline exceeded` from ingress-nginx).
cert-manager's webhook becoming Ready is the litmus test — if it doesn't, fall back
to Approach A.

---

## 4. Known gaps found while reading the files

These are factual observations from the manifests, worth resolving before this is
considered complete.

1. **`05-otel-collector.yaml` still has no `Deployment` and no `ServiceAccount`**
   (confirmed still true as of 2026-09-16 — re-checked, not fixed since this was
   first flagged 2026-08-11). The file defines only a `ConfigMap` and a `Service`.
   The Service selects `app.kubernetes.io/name: otel-collector` and targets named
   ports (`otlp-grpc`, `otlp-http`, `prom-export`, `prom-internal`) that no pod in
   this manifest set defines, and `14-rbac.yaml` binds a ClusterRole to
   `ServiceAccount monitoring/otel-collector` which is never created here. Taken
   at face value, `kubectl apply -f monitoring/` produces a Service with no
   endpoints and every application telemetry path is dead (apps → Collector →
   Tempo/Prometheus/Loki).
   **However:** `V10-DIAGNOSTICS-AND-CONFIG-FIXES.md` (2026-08-11, the same day
   this gap was first noted) shows *real* OTLP application metrics
   (`http_server_request_duration_seconds_count` with live `k8s_pod_name` /
   `service_name` labels from the actual Exora G360 gateway) flowing through
   Prometheus — which is only possible if a Collector pod was running at that
   time. The most likely explanation is the same pattern found in the Prometheus
   incident above: a Deployment/ServiceAccount was created directly against the
   cluster (`kubectl create` / `kubectl apply -f` from an untracked file) and was
   never added back into this manifest set. **Confirmed 2026-09-16:**
   `kubectl get all -n monitoring` shows `pod/otel-collector-956cb7467-jzcnl`,
   `1/1 Running`, age 36 days — the Deployment genuinely exists live and
   telemetry is flowing. It is **not** captured anywhere in this manifest set.
   Capture it (`kubectl -n monitoring get deploy otel-collector -o yaml`,
   strip the cluster-assigned fields) into a checked-in addition to
   `05-otel-collector.yaml`, or `kubectl apply -f monitoring/` against a fresh
   cluster will silently produce a Service with no backing pods.

2. **Logs never reach Loki.** Both instrumentation paths set
   `OTEL_LOGS_EXPORTER=none` / `-Dotel.logs.exporter=none`. The Collector's logs
   pipeline and the entire Loki deployment are correctly wired but will receive
   nothing from applications. Set the logs exporter to `otlp` to activate the
   logs pillar and the Traces→Logs / Logs→Traces correlation described in file 10.

3. **Blackbox targets point at `rego-app-server.default.svc.cluster.local`**, while
   the instrumentation scripts and operator README target `*be` deployments in
   namespaces like `regopshub-sit`. Update the `blackbox-http` job targets in
   `01-prometheus.yaml` to the real Services, or those probes will report
   `probe_success 0` permanently.

4. **Placeholder credentials and endpoints** that must be changed before production:
   Grafana admin password (`02-grafana.yaml`), the PostgreSQL DSN
   (`12-postgres-exporter.yaml`), the Alertmanager webhook `http://127.0.0.1:5001/`
   (`08-alertmanager.yaml`), and the `*.example.com` Ingress hosts (`16-ingress.yaml`).
   **Still `ChangeMe_Admin123!` as of 2026-09-18** — used to push dashboards
   via the API that day, in plaintext, in a chat transcript. Rotate it
   (`kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password='<new>' --dry-run=client -o yaml | kubectl apply -f -`,
   then restart the Grafana pod) once the demo pressure is off.

5. **`prometheus-rules` ConfigMap changes don't auto-apply.** Prometheus is started
   with `--web.enable-lifecycle` but there is no config-reloader sidecar, so after
   editing file 09 you must `kubectl -n monitoring exec deploy/prometheus -- ...`
   or `curl -X POST http://prometheus:9090/-/reload` (or restart the pod).

6. **`postgres-exporter` has been scaled to 0 since 2026-08-11** (see file 12) —
   there is no PostgreSQL in this cluster; the real app database is MySQL. The
   `pg_up`/`PostgreSQLDown` alert and the `postgresql.json` dashboard have no
   data. Replace with `prom/mysqld-exporter` + a matching scrape job, or remove
   the dead alert/dashboard to stop them being mistaken for working coverage.

7. **This directory contains a stale duplicate copy of most manifests** under
   `monitoring/monitoring/` (missing `16-ingress.yaml` entirely, and missing the
   `local-blocks` removal, the postgres-exporter zero-scale, the Grafana
   `root_url` fix, and the datasource `timeInterval` fix present in the
   top-level files). It's unclear whether it's an intentional backup or leftover
   from an extraction step; either delete it or clearly mark it historical so it
   isn't mistaken for the current source of truth.

8. **Two confirmed cases of the live cluster drifting from these checked-in
   YAMLs** (Prometheus's probe timings and memory limit — see the file 01
   section above; likely the OTel Collector Deployment too — see gap #1). Treat
   `kubectl diff -f monitoring/` as a healthy habit before assuming these files
   describe what's actually running.

---

## 5. Incident timeline

Chronological, pulled from dated comments across the manifests plus this
session's Prometheus investigation. Full detail for the first entry lives in
`V10-DIAGNOSTICS-AND-CONFIG-FIXES.md`; everything else is inline in the file
noted.

| Date | What broke | Root cause | Fix | File |
|------|-----------|-----------|-----|------|
| 2026-08-11 | Every Grafana panel using `$__rate_interval` was empty; `$__range` panels were fine | Missing `timeInterval`, so Grafana assumed a 15s scrape and built a ~1m rate window against an agent that pushes every 60s — `rate(...[1m])` matched 0 series | Set `timeInterval: "60s"` on the Prometheus datasource | `10-grafana-datasources.yaml` |
| 2026-08-11 | Same panels *still* empty after the above | PromQL filtered on `deployment_environment_name`, a label that doesn't exist on the metric (the agent emits `deployment.environment`, not the semconv-1.27 `.name` rename) | Renamed the filter to `deployment_environment` across the dashboard | `Exora_G360_SRE_API_Dashboard_v10.json` |
| 2026-08-11 | Tempo pinned at 100% of its 2Gi limit; readiness probe timed out | `local-blocks` processor retained every span in memory for TraceQL metrics that nothing actually queries | Removed `local-blocks` from `metrics_generator.processors` | `03-tempo.yaml` |
| 2026-08-11 | postgres-exporter OOMKilled 57 times over 28 days, stuck `NotReady`, two ReplicaSets alive at once | `DATA_SOURCE_NAME` pointed at a PostgreSQL host that doesn't exist — the app actually runs on MySQL | Scaled to `replicas: 0`; real fix is deploying `mysqld-exporter` instead | `12-postgres-exporter.yaml` |
| 2026-08-11 | A single bad OTLP metric sample discarded up to 2048 points at once | Prometheus' OTLP receiver rejects the whole request on any append error; large batches meant a large blast radius | Cut `send_batch_size`/`send_batch_max_size` from 1024/2048 to 512/512; split the metrics exporter in two so failures are attributable | `05-otel-collector.yaml` |
| 2026-08-12 | Grafana Live / streaming panels silently stopped updating behind the external nginx | `root_url` defaulted to `localhost`; browser's `Origin: https://apm.devopslabs.tech` on the Live websocket didn't match, so Grafana refused the socket | Set `GF_SERVER_DOMAIN` / `GF_SERVER_ROOT_URL` explicitly, protocol hardcoded to `https` | `02-grafana.yaml` |
| 2026-09-16 | Prometheus OOMKilled 136 times over 17h, never became `Ready` | WAL grew to ~4094 segments because repeated kills never let a replay finish long enough to checkpoint — a self-reinforcing spiral against a 2Gi limit | Live-patched memory limit to 6Gi (`kubectl set resources`), confirmed WAL replay completed (`total_replay_duration=6m22s`) and `Server is ready`; file updated to match | `01-prometheus.yaml` |
| 2026-09-16 | Ten starter dashboards all dumped into one flat "Observability" folder, hard to browse as the stack grew | No folder structure — `foldersFromFilesStructure: false` | Switched to `foldersFromFilesStructure: true` + per-key `items:` path remap into six topic folders (Infrastructure/APM/Logs/Tracing/Database/Platform) | `02-grafana.yaml`, `11-grafana-dashboards.yaml` |
| 2026-09-18 | "Request rate by endpoint" / "P95 latency by endpoint" (spanmetrics) rendered as a huge legend table with the chart squeezed to nothing | The real app has ~250 distinct `http_route` values (much larger than the small dev example these panels were built against) — one legend row per route ate the whole panel width | Wrapped both queries in `topk(8, ...)` (top 10 for the errors panel) and moved their legends from `right` to `bottom` | `Exora_G360_SRE_API_Dashboard_v10.json`, `DevopsLabs_APM_API-Performance.json` |
| 2026-09-18 | Environment dropdown only ever offered "dev" — visual clutter, not a bug | Only `dev`-environment apps are currently instrumented; `label_values()` can't return values that don't exist yet | Set the variable to `hide: 2` with `current` pinned to `.*` (match everything) instead of deleting it from every query — reversible once other environments start reporting | All 9 manually-maintained dashboards |
| 2026-09-18 | Picking a different **Service** left **Deployment** showing an unrelated, stale value (e.g. Service=`Rego_BE_Demo` next to Deployment=`api-gateway-backend-dev`) — a real risk of reading one app's Kubernetes health while believing it was another's | The Deployment variable queried `kube_deployment_spec_replicas` filtered only by Namespace — never referenced `$service_name` at all | Re-pointed the query at the app's own promoted `k8s_deployment_name` label on `http_server_request_duration_seconds_count`, scoped by `$service_name` — Deployment (and therefore Pod) now cascades correctly from Service | All 9 manually-maintained dashboards |
| 2026-09-18 | "API REQUESTS" (Tempo trace table) went to "No data", taking the waterfall and trace-scoped logs panels down with it | The Environment-hide fix (row above) set the hidden variable to `.*`, correct for PromQL's regex `=~` — but this panel's TraceQL query used exact-match `resource.deployment.environment = "$deployment_environment"`, which can never equal the literal string `.*` | Removed the exact-match environment clause from the TraceQL query entirely (TraceQL has no regex-match operator to swap to; omitting the clause is the correct "don't filter on this" equivalent) | `Exora_G360_SRE_API_Dashboard_v10.json`, `DevopsLabs_APM_Request-Investigation.json` |

The pattern across nearly every row: a memory/behavior limit that was fine at
low volume became a hard failure at real volume, and the fix was usually
narrower than "give it more memory" — remove the unused feature causing the
pressure (`local-blocks`, the leaking DB exporter) rather than just raising the
ceiling. The 2026-09-16 Prometheus fix is the one exception still pending that
follow-through: the limit was raised to unblock it, but the underlying question
("why did the WAL reach 4089 segments in the first place, and is checkpointing
healthy now") is still open. The 2026-09-18 batch is a related pattern at a
different layer: every one of those three bugs only became visible once a
real, full-sized production app (~250 endpoints, multiple services) started
sending data — the dashboards were built and validated against a much smaller
dev example, and cardinality/scale problems like these don't show up until
real traffic arrives. Worth treating as a standing question for anything new
added to these dashboards: does this still work at real scale, not just
against the one app it was built with.

`apply-dashboards.sh` (repo root) was added the same day — pushes all 9
manually-maintained dashboards into Grafana via its HTTP API in one shot
(creating the APM/Database/Infrastructure/Platform folders if missing),
instead of importing each one by hand through the UI.
