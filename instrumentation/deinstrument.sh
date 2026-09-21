#!/usr/bin/env bash
# =====================================================================
# Revert instrumentation on a Deployment. Safest form: just remove the
# JAVA_TOOL_OPTIONS env var — the JVM then no longer loads the agent.
# The (harmless) init container + emptyDir can stay, or pass --full to
# also strip them.
#
#   ./deinstrument.sh <namespace> <deployment> [--full]
# =====================================================================
set -euo pipefail
NS="${1:?namespace required}"
DEPLOY="${2:?deployment required}"
FULL="${3:-}"

echo ">> Removing JAVA_TOOL_OPTIONS from $NS/$DEPLOY"
kubectl -n "$NS" set env deploy/"$DEPLOY" JAVA_TOOL_OPTIONS-

if [ "$FULL" = "--full" ]; then
  echo ">> Stripping otel-agent init container + volume (strategic merge with null)"
  kubectl -n "$NS" patch deploy "$DEPLOY" --type json -p '[
    {"op":"test","path":"/spec/template/spec/initContainers/0/name","value":"otel-agent"},
    {"op":"remove","path":"/spec/template/spec/initContainers"}
  ]' 2>/dev/null || echo "   (init container not first/only — remove manually if needed)"
fi

kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s
echo ">> Reverted: $NS/$DEPLOY"
