# Automatic Java instrumentation via the OpenTelemetry Operator

The "official", hands-off way to instrument Java apps: annotate a workload
once and the operator injects the OpenTelemetry Java agent into every pod —
no app code or image change, and it survives future image updates.

## How it works
1. **cert-manager** issues TLS certs for the operator's admission webhook.
2. The **OpenTelemetry Operator** runs a mutating webhook.
3. An **Instrumentation** CR (`instrumentation.yaml`) says *how* to instrument
   (endpoint, sampler, Java env).
4. You add one **annotation** to a Deployment; on rollout the operator injects
   the agent init container + env automatically.

## ⚠️ Prerequisite / risk
The operator and cert-manager both use admission webhooks. This cluster has
shown a webhook reachability problem (ingress-nginx `context deadline
exceeded`). **Install cert-manager first and confirm it is healthy** — that is
the test that webhooks work here. If cert-manager's webhook does not become
Ready, stop and use the script approach (`../instrument-all-be.sh`) instead.

## Install (run on the cluster)

```bash
# 1) cert-manager (this is also the webhook litmus test)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
kubectl -n cert-manager get pods           # all 3 must be Running/Ready

# 2) OpenTelemetry Operator
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
kubectl -n opentelemetry-operator-system rollout status deploy/opentelemetry-operator-controller-manager --timeout=180s

# 3) The Instrumentation definition
kubectl apply -f instrumentation.yaml
```

## Opt workloads in

Per deployment (recommended — target only backends):
```bash
kubectl -n regopshub-sit patch deploy sit-regopsbe --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-java":"monitoring/rego-instrumentation"}}}}}'
```

All `*be` deployments across all namespaces (one-time; the operator handles
the rest forever):
```bash
kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
| awk '$2 ~ /be$/{print}' \
| while read -r NS DEP; do
    case "$NS" in kube-*|monitoring|cert-manager|opentelemetry-operator-system|local-path-storage|ingress-nginx) continue;; esac
    kubectl -n "$NS" patch deploy "$DEP" --type merge -p \
      '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-java":"monitoring/rego-instrumentation"}}}}}'
    echo "annotated $NS/$DEP"
  done
```

## Verify
```bash
kubectl -n regopshub-sit get pod -l app=sit-regopsbe -o jsonpath='{.items[0].spec.initContainers[*].name}'
# -> should include: opentelemetry-auto-instrumentation-java
```
Then generate traffic and check Grafana (Explore → Prometheus: `calls_total`).

## Revert
Remove the annotation and roll out; the operator stops injecting:
```bash
kubectl -n <ns> patch deploy <dep> --type json -p \
  '[{"op":"remove","path":"/spec/template/metadata/annotations/instrumentation.opentelemetry.io~1inject-java"}]'
```
Uninstall entirely: `kubectl delete -f instrumentation.yaml`, then delete the
operator and cert-manager manifests.
