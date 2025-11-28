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

# Check for OpenTelemetry Operator
if ! oc get crd opentelemetrycollectors.opentelemetry.io &> /dev/null; then
  echo "Error: OpenTelemetry Operator is not installed. Please install it from OperatorHub."
  exit 1
fi
echo "✅ OpenTelemetry Operator is installed"

oc apply -f "$PROJECT_ROOT/deploy/storage/minio.yaml" -n ${NAMESPACE}

# Deploy OpenTelemetry Collector RBAC and CR
echo "Deploying OpenTelemetry Collector..."
oc apply -f "$PROJECT_ROOT/deploy/otel-collector/rbac.yaml" -n ${NAMESPACE}
oc apply -f "$PROJECT_ROOT/deploy/otel-collector/collector.yaml" -n ${NAMESPACE}

# Wait for collector to be ready
echo "Waiting for OpenTelemetry Collector to be ready..."
sleep 5

# Poll for collector readiness with timeout
timeout=300
elapsed=0
collector_ready=false

while [ $elapsed -lt $timeout ]; do
  # Check if deployment exists and is ready
  deployment_found=false
  for deployment_name in otel-collector-collector otel-collector; do
    if oc get deployment "$deployment_name" -n ${NAMESPACE} &>/dev/null; then
      deployment_found=true
      ready_replicas=$(oc get deployment "$deployment_name" -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      desired_replicas=$(oc get deployment "$deployment_name" -n ${NAMESPACE} -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
      if [ "$ready_replicas" = "$desired_replicas" ] && [ "$ready_replicas" != "0" ]; then
        echo "✅ OpenTelemetry Collector deployment '$deployment_name' is ready ($ready_replicas/$desired_replicas replicas)"
        collector_ready=true
        break 2
      else
        echo "⏳ OpenTelemetry Collector deployment '$deployment_name' not ready yet ($ready_replicas/$desired_replicas replicas)..."
      fi
    fi
  done
  
  # If no deployment found, check for pods directly
  if [ "$deployment_found" = false ]; then
    pod_count=$(oc get pods -n ${NAMESPACE} -l app.kubernetes.io/name=opentelemetry-collector --no-headers 2>/dev/null | wc -l)
    if [ "$pod_count" -gt 0 ]; then
      ready_pods=$(oc get pods -n ${NAMESPACE} -l app.kubernetes.io/name=opentelemetry-collector --no-headers 2>/dev/null | grep -c "Running" || echo "0")
      if [ "$ready_pods" -gt 0 ]; then
        echo "✅ OpenTelemetry Collector pods are running ($ready_pods pods)"
        collector_ready=true
        break
      else
        echo "⏳ OpenTelemetry Collector pods exist but not ready yet..."
      fi
    else
      echo "⏳ Waiting for OpenTelemetry Collector resources to be created..."
    fi
  fi
  
  sleep 5
  elapsed=$((elapsed + 5))
done

if [ "$collector_ready" = false ]; then
  echo "⚠️  Warning: OpenTelemetry Collector may not be fully ready, but continuing..."
fi

oc apply -f "$PROJECT_ROOT/deploy/tempo-monolithic/base/tempo.yaml" -n ${NAMESPACE}

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
