#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

NAMESPACE=tempo-perf-test

if ! oc get namespace "$NAMESPACE" > /dev/null 2>&1; then
  echo "Creating namespace $NAMESPACE..."
  oc create namespace "$NAMESPACE"
else
  echo "Namespace $NAMESPACE already exists. Continuing..."
fi

oc apply -f "$PROJECT_ROOT/deploy/storage/minio.yaml" -n ${NAMESPACE}

oc apply -f "$PROJECT_ROOT/deploy/tempo-stack/stack.yaml" -n ${NAMESPACE}

sleep 10

while true; do
  # Count pods that are not in Running or Completed state
  not_ready=$(oc get pods -n "$NAMESPACE" --no-headers | awk '{
    split($2, ready, "/");
    if (($3 != "Running" && $3 != "Completed") || (ready[1] != ready[2])) {
      print $0;
    }
  }')

  if [ -z "$not_ready" ]; then
    echo "✅ All pods in '$NAMESPACE' are Running/Completed and Ready."
    break
  else
    echo "⏳ Waiting for all pods to be Running and Ready in '$NAMESPACE'..."
    echo "$not_ready"
    sleep 5
  fi
done
