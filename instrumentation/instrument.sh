#!/usr/bin/env bash
# =====================================================================
# Attach the OpenTelemetry Java agent to ONE Deployment — no app code or
# image change. The agent jar is delivered by an init container into a
# shared emptyDir; JAVA_TOOL_OPTIONS makes the JVM load it at startup.
#
# Usage:
#   ./instrument.sh <namespace> <deployment> [service-name] [environment]
#
# Env overrides:
#   OTEL_ENDPOINT     (default http://otel-collector.monitoring:4317)
#   OTEL_AGENT_IMAGE  (default ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.11.0)
# =====================================================================
set -euo pipefail

NS="${1:?namespace required}"
DEPLOY="${2:?deployment required}"
SVC="${3:-$DEPLOY}"
ENVIRONMENT="${4:-$NS}"

COLLECTOR="${OTEL_ENDPOINT:-http://otel-collector.monitoring.svc.cluster.local:4317}"
AGENT_IMAGE="${OTEL_AGENT_IMAGE:-ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.11.0}"

CONTAINER="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].name}')"

# Guard: never clobber an existing JAVA_TOOL_OPTIONS (may hold -Xmx etc.)
if kubectl -n "$NS" get deploy "$DEPLOY" \
     -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' \
   | tr ' ' '\n' | grep -qx JAVA_TOOL_OPTIONS; then
  echo "!! $NS/$DEPLOY already has JAVA_TOOL_OPTIONS — skipping (merge manually)."
  exit 2
fi

echo ">> Instrumenting $NS/$DEPLOY  (container=$CONTAINER, service.name=$SVC, env=$ENVIRONMENT)"

kubectl -n "$NS" patch deploy "$DEPLOY" --type strategic --patch "$(cat <<EOF
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
        - name: ${CONTAINER}
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/otel/opentelemetry-javaagent.jar -Dotel.service.name=${SVC} -Dotel.resource.attributes=deployment.environment=${ENVIRONMENT} -Dotel.exporter.otlp.endpoint=${COLLECTOR} -Dotel.exporter.otlp.protocol=grpc -Dotel.traces.exporter=otlp -Dotel.metrics.exporter=otlp -Dotel.logs.exporter=none -Dotel.instrumentation.common.default-enabled=true -Dotel.instrumentation.jdbc.datasource.enabled=true -Dotel.instrumentation.spring-webmvc.enabled=true"
          volumeMounts:
            - name: otel-agent
              mountPath: /otel
EOF
)"

kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s
echo ">> Done: $NS/$DEPLOY"
