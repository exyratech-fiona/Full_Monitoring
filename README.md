# Kubernetes Observability Stack (OpenTelemetry + Grafana LGTM + Prometheus)

A production-ready, **Helm-free** monitoring and observability platform for a
Spring Boot backend instrumented with the OpenTelemetry Java Agent. Everything
is plain Kubernetes YAML and deploys with a single `kubectl apply`.

```
Spring Boot app (OTel Java agent)
        │  OTLP gRPC :4317
        ▼
OpenTelemetry Collector ──► Tempo   (traces)
        │              ──► Prometheus (metrics, scraped from :8889)
        │              ──► Loki      (logs, OTLP)
        ▼
     Grafana  ◄── datasources (Prometheus / Tempo / Loki) with full
                  metrics ⇄ traces ⇄ logs correlation
```

## Components

| File | Component | Notes |
|------|-----------|-------|
| `00-namespace.yaml` | Namespace `monitoring` | |
| `01-prometheus.yaml` | Prometheus + config + scrape jobs | remote-write receiver enabled |
| `02-grafana.yaml` | Grafana + admin Secret | provisioned datasources & dashboards |
| `03-tempo.yaml` | Grafana Tempo | traces, service-graph metrics |
| `04-loki.yaml` | Grafana Loki | logs via OTLP |
| `05-otel-collector.yaml` | OTel Collector (contrib) | OTLP in, k8sattributes, spanmetrics |
| `06-node-exporter.yaml` | Node Exporter DaemonSet | host metrics |
| `07-kube-state-metrics.yaml` | kube-state-metrics | K8s object state |
| `08-alertmanager.yaml` | Alertmanager | alert routing |
| `09-prometheus-rules.yaml` | Alert rules | all requested alerts |
| `10-grafana-datasources.yaml` | Datasource provisioning | correlation wiring |
| `11-grafana-dashboards.yaml` | Dashboard provisioning | 10 starter dashboards |
| `12-postgres-exporter.yaml` | PostgreSQL Exporter | **edit the DSN Secret** |
| `13-blackbox-exporter.yaml` | Blackbox Exporter | probes actuator endpoints |
| `14-rbac.yaml` | ClusterRoles / bindings | Prometheus, OTel, KSM |
| `15-pvc.yaml` | PersistentVolumeClaims | uses default StorageClass |
| `16-ingress.yaml` | Ingress (optional) | NGINX; edit hosts |

All images are official / upstream (`prom/*`, `grafana/*`,
`otel/opentelemetry-collector-contrib`, `registry.k8s.io/kube-state-metrics`,
`quay.io/prometheuscommunity/postgres-exporter`).

## Deploy

```bash
kubectl apply -f monitoring/
```

Files are numbered so a plain `apply -f` creates them in a sensible order.
`kubectl apply` is declarative, so re-running is safe and idempotent.

Watch it come up:

```bash
kubectl -n monitoring get pods -w
```

## REQUIRED edits before production

1. **Grafana admin password** — `02-grafana.yaml`, Secret `grafana-admin`.
2. **PostgreSQL DSN** — `12-postgres-exporter.yaml`, Secret
   `postgres-exporter-secret` (`DATA_SOURCE_NAME`). Use a read-only role.
   Format: `postgresql://USER:PASSWORD@HOST:PORT/DBNAME?sslmode=disable`.
   Also set `replicas: 1` on the Deployment (it's `0` until this is real —
   see the comment block above it for why).

   **Don't know the real host/credentials?** Check whether a Postgres
   instance is even running *inside* this cluster before looking elsewhere
   (it likely isn't — an external/managed database is common):
   ```bash
   # Via kubectl, if you have cluster access:
   kubectl get svc,pods -A | grep -i postgres

   # Via Prometheus (through Grafana's datasource proxy), no cluster access needed:
   curl -u admin:<grafana-password> --data-urlencode \
     'query=kube_pod_info{pod=~"(?i).*postgres.*"}' \
     'http://<grafana-host>/api/datasources/proxy/uid/prometheus/api/v1/query'
   ```
   No result from either means the database is external — ask whoever
   manages the application that uses it (or check that app's own config/
   secrets, e.g. `SPRING_DATASOURCE_URL` / `.env` — not this repo) for the
   real connection details, rather than guessing.
3. **MySQL DSNs** — `17-mysql-exporter.yaml` is a template with two example
   environments (`dev`, `prod`) and `CHANGE_ME_*` placeholders in each
   Secret's `DATA_SOURCE_NAME`. Copy/rename the block per real environment,
   fill in real values, and add a matching `static_configs` entry (with an
   `environment` label) to the `mysql-exporter` job in `01-prometheus.yaml`.
   DSN format: `USER:PASSWORD@tcp(HOST:3306)/` (note: no `mysql://` prefix,
   unlike the Postgres DSN above — mysqld_exporter's format differs).
4. **App service name / namespace** — the blackbox probe targets and the
   PostgreSQL host default to `rego-app-server.default...` and
   `postgres.default...`. Update `01-prometheus.yaml` (job `blackbox-http`)
   and the DSN to match your app.
5. **StorageClass** — `15-pvc.yaml` assumes a *default* StorageClass. If you
   don't have one, uncomment `storageClassName` on each PVC.
6. **Ingress hosts / TLS** — `16-ingress.yaml` (or delete it and use
   `port-forward`).

## Connecting your app to the Collector

Your agent already points at `http://otel-collector:4317`. That short name
only resolves **inside the same namespace**. Since the Collector lives in
`monitoring`, do one of the following in your app's namespace (no app change
needed):

**Option A — alias Service (recommended):** create an `ExternalName` Service
named `otel-collector` in your app's namespace:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: default          # <-- your app's namespace
spec:
  type: ExternalName
  externalName: otel-collector.monitoring.svc.cluster.local
  ports:
    - name: otlp-grpc
      port: 4317
```

**Option B:** deploy `05-otel-collector.yaml` into your app's namespace instead
of `monitoring`.

## Accessing the UIs (without Ingress)

```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000       # Grafana
kubectl -n monitoring port-forward svc/prometheus 9090:9090    # Prometheus
kubectl -n monitoring port-forward svc/alertmanager 9093:9093  # Alertmanager
```

Grafana → http://localhost:3000 (admin / password from the Secret). Datasources
and the topic-folder dashboards (Infrastructure/APM/Logs/Tracing/Database/Platform)
are provisioned automatically.

## Correlation (metrics ⇄ traces ⇄ logs)

Configured in `10-grafana-datasources.yaml`:

- **Metrics → Traces:** Prometheus exemplars link to Tempo (`exemplarTraceIdDestinations`).
- **Traces → Logs:** Tempo `tracesToLogsV2` jumps to Loki filtered by trace ID.
- **Traces → Metrics:** Tempo `tracesToMetrics` + service map (Prometheus).
- **Logs → Traces:** Loki derived field on `trace_id` links back to Tempo.

Trace IDs flow because the app logs through the OTel agent, the Collector ships
logs to Loki over OTLP with structured metadata, and Tempo's metrics-generator
remote-writes span/service-graph metrics into Prometheus.

## Alerts included (`09-prometheus-rules.yaml`)

High CPU · High Memory · Pod Restart · CrashLoopBackOff · OOMKilled · Disk
Usage · Node Not Ready · JVM Heap > 90% · High GC Pause · HTTP 5xx · High
Latency · PostgreSQL Down.

> JVM/HTTP expressions use OpenTelemetry metric names
> (`jvm_memory_used_bytes`, `calls_total`, `duration_milliseconds_bucket`).
> Confirm them against your agent version in Prometheus → *Graph* and tweak if
> needed.

## Dashboards

Ten starter dashboards are provisioned, sorted into topic folders:

| Folder | Dashboards |
|--------|-----------|
| Infrastructure | Kubernetes Cluster, Nodes, Pods |
| APM | JVM, Spring Boot, HTTP Requests |
| Database | PostgreSQL *(inactive — see `12-postgres-exporter.yaml`)* |
| Platform | OpenTelemetry Collector |
| Tracing | Tempo |
| Logs | Loki |

`Exora_G360_SRE_API_Dashboard_v10.json` (repo root) plus 8 lighter, topic-scoped
dashboards in `standalone-dashboards/` are separately maintained and **not**
part of the auto-provisioned ConfigMap above — see "Pushing dashboard changes
to Grafana" below for how to get them (and any edits to them) into Grafana.

For fuller community dashboards, import by ID (Grafana → Dashboards → New →
Import):

| ID | Dashboard |
|----|-----------|
| 1860 | Node Exporter Full |
| 13332 | kube-state-metrics |
| 3662 / 6417 | Kubernetes cluster / pods |
| 4701 | JVM (Micrometer) |
| 9628 | PostgreSQL |
| 7587 | Blackbox Exporter |

### Pushing dashboard changes to Grafana

`Exora_G360_SRE_API_Dashboard_v10.json` and everything in `standalone-dashboards/`
are plain JSON files in this repo — editing them does **nothing** in Grafana
until pushed. Two scripts do that, both idempotent (safe to re-run, and they
update in place by UID rather than creating duplicates):

**Option A — `apply-dashboards.sh`** (bash + `curl` + `jq`; use this on Linux,
e.g. `k8master01`):

```bash
GRAFANA_URL=http://<node-ip>:30300 GRAFANA_PASSWORD='<grafana-admin password>' ./apply-dashboards.sh
```

**Option B — `push-dashboards.js`** (Node.js 18+, no `jq` needed; use this on
Windows or anywhere `jq` isn't installed):

```bash
export GRAFANA_URL=http://<node-ip>:30300
export GRAFANA_PASSWORD='<grafana-admin password>'
node push-dashboards.js
```

(PowerShell: `$env:GRAFANA_URL="..."; $env:GRAFANA_PASSWORD="..."; node push-dashboards.js`)

Both scripts, run from this directory:
1. Look up each destination folder (APM / Database / Infrastructure / Platform)
   by name via the Grafana API, creating it first if it doesn't exist yet.
2. Push all 9 dashboards with `overwrite: true`, so re-running after an edit
   updates the existing dashboard instead of duplicating it.
3. Print a direct URL for each one that succeeds, or Grafana's raw error for
   any that fail.

Use the NodePort URL (`http://<node-ip>:30300`) rather than
`https://apm.devopslabs.tech` unless you've confirmed the TLS/certbot stage on
the external nginx has landed — see `nginx-apm.devopslabs.tech.conf` and
`ARCHITECTURE.md`.

## Notes / production hardening

- Single-replica stateful components (Prometheus, Grafana, Tempo, Loki,
  Alertmanager) use `Recreate` + `ReadWriteOnce` PVCs. For HA, move to their
  respective distributed/microservices modes.
- Local filesystem storage for Tempo/Loki is fine for small/medium volumes;
  for scale, switch their `storage` backends to S3/GCS.
- Add `NetworkPolicies` and TLS between components for a locked-down cluster.
- Retention defaults: Prometheus 15d, Tempo 7d, Loki 7d — tune to taste.
