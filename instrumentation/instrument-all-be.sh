#!/usr/bin/env bash
# =====================================================================
# Discover backend (BE) deployments across ALL namespaces and attach the
# OpenTelemetry Java agent to each — no app code/image change.
#
# SAFE BY DEFAULT: runs as a DRY-RUN (just lists what it would do).
# Add --apply to actually patch.
#
#   ./instrument-all-be.sh            # dry-run: show candidates
#   ./instrument-all-be.sh --apply    # instrument all candidates
#
# Tunables (env vars):
#   NAME_REGEX        deployment-name match         (default: 'be$'  -> *be)
#   NS_EXCLUDE_REGEX  namespaces to skip
#   OTEL_ENDPOINT     collector OTLP endpoint        (default monitoring collector)
#   OTEL_AGENT_IMAGE  java agent image
#
# NOTE: matching is by NAME (your BE apps end in 'be', FE end in 'fe').
# It only targets Java apps in practice; a non-Java match just ignores
# JAVA_TOOL_OPTIONS harmlessly. Review the dry-run before --apply.
# =====================================================================
set -uo pipefail

NAME_REGEX="${NAME_REGEX:-be$}"
NS_EXCLUDE_REGEX="${NS_EXCLUDE_REGEX:-^(kube-system|kube-public|kube-node-lease|monitoring|local-path-storage|ingress-nginx|cert-manager)$}"
COLLECTOR="${OTEL_ENDPOINT:-http://otel-collector.monitoring.svc.cluster.local:4317}"
AGENT_IMAGE="${OTEL_AGENT_IMAGE:-ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.11.0}"

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

echo "Mode: $([ "$APPLY" = true ] && echo APPLY || echo DRY-RUN)   name=~/$NAME_REGEX/   endpoint=$COLLECTOR"
printf '%-24s %-30s %-11s %s\n' NAMESPACE DEPLOYMENT ACTION NOTE
printf '%-24s %-30s %-11s %s\n' "------------------------" "------------------------------" "-----------" "----"

env_from_ns() {
  local ns="$1" e
  e="$(echo "$ns" | grep -oiE 'dev|sit|demo|uat|preprod|prod|staging' | head -1 || true)"
  [ -n "$e" ] && echo "$e" || echo "$ns"
}

patch_one() {
  local ns="$1" dep="$2" svc="$3" environment="$4" container
  container="$(kubectl -n "$ns" get deploy "$dep" -o jsonpath='{.spec.template.spec.containers[0].name}')"
  kubectl -n "$ns" patch deploy "$dep" --type strategic --patch "$(cat <<EOF
spec:
  template:
    spec:
      initContainers:
        - name: otel-agent
          image: ${AGENT_IMAGE}
          command: ["cp", "/javaagent.jar", "/otel/opentelemetry-javaagent.jar"]
          volumeMounts:
            - name: otel-agent
              mountPath: /otel
      volumes:
        - name: otel-agent
          emptyDir: {}
      containers:
        - name: ${container}
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/otel/opentelemetry-javaagent.jar -Dotel.service.name=${svc} -Dotel.resource.attributes=deployment.environment=${environment} -Dotel.exporter.otlp.endpoint=${COLLECTOR} -Dotel.exporter.otlp.protocol=grpc -Dotel.traces.exporter=otlp -Dotel.metrics.exporter=otlp -Dotel.logs.exporter=none -Dotel.instrumentation.common.default-enabled=true -Dotel.instrumentation.jdbc.datasource.enabled=true -Dotel.instrumentation.spring-webmvc.enabled=true"
          volumeMounts:
            - name: otel-agent
              mountPath: /otel
EOF
)" >/dev/null 2>&1
}

kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
| while read -r NS DEP; do
    [ -z "${NS:-}" ] && continue
    echo "$NS"  | grep -qE "$NS_EXCLUDE_REGEX" && continue
    echo "$DEP" | grep -qE "$NAME_REGEX"       || continue

    # already instrumented?
    if kubectl -n "$NS" get deploy "$DEP" -o jsonpath='{.spec.template.spec.initContainers[*].name}' \
         | tr ' ' '\n' | grep -qx otel-agent; then
      printf '%-24s %-30s %-11s %s\n' "$NS" "$DEP" "skip" "already instrumented"; continue
    fi
    # existing JAVA_TOOL_OPTIONS -> leave for manual merge
    if kubectl -n "$NS" get deploy "$DEP" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' \
         | tr ' ' '\n' | grep -qx JAVA_TOOL_OPTIONS; then
      printf '%-24s %-30s %-11s %s\n' "$NS" "$DEP" "skip" "has JAVA_TOOL_OPTIONS (manual)"; continue
    fi

    ENVIRONMENT="$(env_from_ns "$NS")"
    if [ "$APPLY" = true ]; then
      if patch_one "$NS" "$DEP" "$DEP" "$ENVIRONMENT"; then
        printf '%-24s %-30s %-11s %s\n' "$NS" "$DEP" "PATCHED" "service.name=$DEP env=$ENVIRONMENT"
      else
        printf '%-24s %-30s %-11s %s\n' "$NS" "$DEP" "FAIL" "patch error"
      fi
    else
      printf '%-24s %-30s %-11s %s\n' "$NS" "$DEP" "candidate" "would set env=$ENVIRONMENT"
    fi
done

echo
echo "Done. $([ "$APPLY" = true ] && echo 'Watch rollouts: kubectl get pods -A | grep -iE \"be-\"' || echo 'Re-run with --apply to instrument the candidates above.')"
