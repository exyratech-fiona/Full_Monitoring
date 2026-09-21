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
3. **App service name / namespace** — the blackbox probe targets and the
   PostgreSQL host default to `rego-app-server.default...` and
   `postgres.default...`. Update `01-prometheus.yaml` (job `blackbox-http`)
   and the DSN to match your app.
4. **StorageClass** — `15-pvc.yaml` assumes a *default* StorageClass. If you
   don't have one, uncomment `storageClassName` on each PVC.
5. **Ingress hosts / TLS** — `16-ingress.yaml` (or delete it and use
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
and the `Observability` dashboard folder are provisioned automatically.

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

Ten starter dashboards are provisioned into the **Observability** folder:
Kubernetes Cluster, Nodes, Pods, JVM, Spring Boot, PostgreSQL, HTTP Requests,
OpenTelemetry Collector, Tempo, Loki.

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

## Notes / production hardening

- Single-replica stateful components (Prometheus, Grafana, Tempo, Loki,
  Alertmanager) use `Recreate` + `ReadWriteOnce` PVCs. For HA, move to their
  respective distributed/microservices modes.
- Local filesystem storage for Tempo/Loki is fine for small/medium volumes;
  for scale, switch their `storage` backends to S3/GCS.
- Add `NetworkPolicies` and TLS between components for a locked-down cluster.
- Retention defaults: Prometheus 15d, Tempo 7d, Loki 7d — tune to taste.
