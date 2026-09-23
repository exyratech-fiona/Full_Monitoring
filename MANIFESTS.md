# Manifest Reference — one row per file

Quick lookup: which Kubernetes objects each YAML file creates, and what they're
for. This is the "what's in the box" index. For *how data flows between them*
(push/pull, ports, correlation, and the incident history behind several of
these configs), see [`ARCHITECTURE.md`](ARCHITECTURE.md).

Applied in numeric order (`kubectl apply -f monitoring/`), namespace `monitoring`
throughout unless noted.

| # | File | Kubernetes objects created | Purpose |
|---|------|----------------------------|---------|
| 00 | `00-namespace.yaml` | `Namespace/monitoring` | Creates the namespace; sets Pod Security Admission to `privileged` (required by node-exporter's host access and the root `chown` init containers used elsewhere). |
| 01 | `01-prometheus.yaml` | `ServiceAccount/prometheus`, `ConfigMap/prometheus-config`, `Deployment/prometheus`, `Service/prometheus` (:9090) | The metrics store. Scrapes exporters/kubelet/cAdvisor/apiserver (pull) **and** receives OTLP metrics + remote-write (push). Evaluates alerting rules. 15-day retention on a 20Gi PVC. |
| 02 | `02-grafana.yaml` | `ServiceAccount/grafana`, `Secret/grafana-admin`, `Deployment/grafana`, `Service/grafana` (NodePort 30300) | The query/visualization UI. Never receives telemetry — pulls from Prometheus/Tempo/Loki when a dashboard renders. Provisioned from ConfigMaps in files 10 & 11. |
| 03 | `03-tempo.yaml` | `ConfigMap/tempo-config`, `Deployment/tempo`, `Service/tempo` (:3200 HTTP, :4317 OTLP gRPC, :4318 OTLP HTTP) | Trace store (monolithic mode). Receives OTLP traces from the Collector; its metrics-generator also derives service-graph/RED metrics and remote-writes them into Prometheus. 7-day retention on a 15Gi PVC. |
| 04 | `04-loki.yaml` | `ConfigMap/loki-config`, `Deployment/loki`, `Service/loki` (:3100 HTTP, :9096 gRPC) | Log store (monolithic mode). Receives logs natively over OTLP (`/otlp/v1/logs`) from the Collector. 7-day retention on a 15Gi PVC. Structured metadata enabled so `trace_id` survives for logs↔traces correlation. |
| 05 | `05-otel-collector.yaml` | `ConfigMap/otel-collector-config`, `Service/otel-collector` (:4317, :4318, :8888, :8889) | Defines the Collector's pipeline config (receivers, processors, the `spanmetrics` connector, exporters to Tempo/Prometheus/Loki) and its Service. **No `Deployment`/`ServiceAccount` here** — one exists live in the cluster but isn't captured in this file; see `ARCHITECTURE.md` §4 gap 1. |
| 06 | `06-node-exporter.yaml` | `ServiceAccount/node-exporter`, `DaemonSet/node-exporter`, `Service/node-exporter` (headless, :9100) | Host-level CPU/memory/disk/network metrics, one pod per node (`hostNetwork`, `hostPID`, tolerates all taints). Pull-only. |
| 07 | `07-kube-state-metrics.yaml` | `ServiceAccount/kube-state-metrics`, `Deployment/kube-state-metrics`, `Service/kube-state-metrics` (:8080, :8081) | Turns Kubernetes object *state* (pod phase, restarts, waiting/terminated reasons, node conditions) into metrics. Pull-only; needs the ClusterRole in file 14. |
| 08 | `08-alertmanager.yaml` | `ConfigMap/alertmanager-config`, `Deployment/alertmanager`, `Service/alertmanager` (:9093) | Receives firing alerts from Prometheus, dedupes/groups/routes them. Currently routes everything to a placeholder webhook (`http://127.0.0.1:5001/`) — no real Slack/email/PagerDuty wired up yet. |
| 09 | `09-prometheus-rules.yaml` | `ConfigMap/prometheus-rules` (5 rule files) | Alerting rules: node health (`node.rules.yml`), pod/workload health (`workload.rules.yml`), JVM (`jvm.rules.yml`), HTTP RED metrics (`http.rules.yml`), PostgreSQL (`postgres.rules.yml` — currently dead, see file 12). Mounted into Prometheus and evaluated there. |
| 10 | `10-grafana-datasources.yaml` | `ConfigMap/grafana-datasources` | Provisions the three Grafana datasources (Prometheus, Tempo, Loki) with fixed UIDs and all the metrics↔traces↔logs correlation config (exemplars, `tracesToLogsV2`, `tracesToMetrics`, derived fields). |
| 11 | `11-grafana-dashboards.yaml` | `ConfigMap/grafana-dashboard-provider`, `ConfigMap/grafana-dashboards` | Auto-provisions 10 starter dashboards, sorted into 6 topic folders (Infrastructure, APM, Logs, Tracing, Database, Platform — see `ARCHITECTURE.md`'s file 11 section) via `foldersFromFilesStructure` and a path remap in `02-grafana.yaml`. |
| 12 | `12-postgres-exporter.yaml` | One Secret, Deployment, and Service per database (:9187) | PostgreSQL metrics exporters for multiple databases. See `POSTGRES-EXPORTER-GUIDE.md` for adding or removing a database. |
| 13 | `13-blackbox-exporter.yaml` | `ConfigMap/blackbox-exporter-config`, `Deployment/blackbox-exporter`, `Service/blackbox-exporter` (:9115) | Synthetic/black-box HTTP probing — the only component that tests the app from the outside. Driven by Prometheus' `blackbox-http` job (defined in file 01) against the app's actuator endpoints. |
| 14 | `14-rbac.yaml` | 3× `ClusterRole` + `ClusterRoleBinding` (`monitoring-prometheus`, `monitoring-otel-collector`, `monitoring-kube-state-metrics`) | Cluster-scoped read permissions Prometheus (node/pod/service discovery + cAdvisor/kubelet proxy), the Collector (`k8sattributes` enrichment), and kube-state-metrics (broad object watch) all need. |
| 15 | `15-pvc.yaml` | 5× `PersistentVolumeClaim` (`prometheus-data` 20Gi, `grafana-data` 5Gi, `tempo-data` 15Gi, `loki-data` 15Gi, `alertmanager-data` 2Gi) | Storage for every stateful component, `ReadWriteOnce` via the cluster's default StorageClass. RWO is why each Deployment uses a `Recreate` rollout strategy. |
| 16 | `16-ingress.yaml` | 3× `Ingress` (grafana, prometheus, alertmanager) | Optional NGINX Ingress routes (`*.example.com` placeholders). Prometheus/Alertmanager get a basic-auth annotation since neither has built-in auth. Grafana is also reachable via its own NodePort (file 02), so this file can be skipped if an external nginx fronts that instead. |
| 17 | `17-mysql-exporter.yaml` | `Secret`/`Deployment`/`Service` × 2 (`mysql-exporter-dev`, `mysql-exporter-prod`, as examples) | **Template, not yet real** — added 2026-09-18. One exporter per environment (the app's real DB landscape has several environments and mixed engines: MySQL, Postgres, others). `DATA_SOURCE_NAME` in each Secret is a `CHANGE_ME_*` placeholder; copy/rename the example blocks per real environment before applying. Matching Prometheus job `mysql-exporter` is in `01-prometheus.yaml`. |
| — | `instrumentation/otel-operator/instrumentation.yaml` | `Instrumentation/rego-instrumentation` (`opentelemetry.io/v1alpha1`, namespace `monitoring`) | OpenTelemetry Operator config: how to auto-inject the Java agent into a workload's pods via a single annotation (`instrumentation.opentelemetry.io/inject-java`), with no app image/code change. Points the agent at the in-cluster Collector, 100% trace sampling. |

## Not YAML, but part of the same pipeline

| File | What it is |
|------|------------|
| `Exora_G360_SRE_API_Dashboard_v10.json` | A hand-tuned Grafana dashboard (not auto-provisioned via file 11) built specifically for the Exora G360 API gateway app. See `V10-DIAGNOSTICS-AND-CONFIG-FIXES.md` for the label-mismatch bug history behind its current v10 form. |
| `nginx-apm.devopslabs.tech.conf` | The external reverse-proxy config (not a k8s object) that fronts Grafana's NodePort at `https://apm.devopslabs.tech`. Referenced from the Grafana env-var notes in `ARCHITECTURE.md`. |
| `instrumentation/instrument.sh`, `instrument-all-be.sh`, `deinstrument.sh` | Shell scripts that patch a Deployment's pod spec directly (init container + `JAVA_TOOL_OPTIONS`) as an alternative to the Operator CR above — no cluster prerequisites, but not declarative. |

## A note on this directory's duplicate copy

`monitoring/monitoring/` contains an older copy of most of these files (missing
`16-ingress.yaml` entirely, and missing several fixes present in the top-level
copies — see `ARCHITECTURE.md` §4 gap 7). This reference describes the
**top-level** files only; treat the nested copy as stale until it's reconciled
or removed.
