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

# Deploy MinIO storage
echo "Deploying MinIO storage..."
oc apply -f "$PROJECT_ROOT/deploy/storage/minio.yaml" -n ${NAMESPACE}

# Wait for MinIO to be ready before deploying Tempo
echo "Waiting for MinIO to be ready..."
sleep 5

timeout=120
elapsed=0
minio_ready=false

while [ $elapsed -lt $timeout ]; do
  minio_pods=$(oc get pods -n ${NAMESPACE} -l app.kubernetes.io/name=minio --no-headers 2>/dev/null || true)
  
  if [ -n "$minio_pods" ]; then
    minio_pods_count=$(echo "$minio_pods" | wc -l | tr -d ' ')
    minio_pods_count=${minio_pods_count:-0}
    ready_pods_output=$(echo "$minio_pods" | awk '{
      split($2, ready, "/");
      if ($3 == "Running" && ready[1] == ready[2] && ready[1] > 0) {
        print $0;
      }
    }')
    if [ -n "$ready_pods_output" ]; then
      ready_pods=$(echo "$ready_pods_output" | wc -l | tr -d ' ')
    else
      ready_pods=0
    fi
    ready_pods=${ready_pods:-0}
    
    if [ "$ready_pods" -gt 0 ]; then
      echo "✅ MinIO is running and ready ($ready_pods/$minio_pods_count pod(s))"
      minio_ready=true
      break
    else
      echo "⏳ Waiting for MinIO to be ready... ($minio_pods_count pod(s) exist but not ready yet)"
    fi
  else
    echo "⏳ Waiting for MinIO pods to be created..."
  fi
  
  sleep 5
  elapsed=$((elapsed + 5))
done

if [ "$minio_ready" = false ]; then
  echo "⚠️  Warning: MinIO may not be fully ready, but continuing with Tempo deployment..."
fi

# Deploy Tempo (after MinIO is ready)
echo "Deploying Tempo Monolithic..."
oc apply -f "$PROJECT_ROOT/deploy/tempo-monolithic/base/tempo.yaml" -n ${NAMESPACE}

# Wait for Tempo to be ready before deploying OpenTelemetry Collector
echo "Waiting for Tempo to be ready..."
sleep 5

# Poll for Tempo readiness with timeout
timeout=300
elapsed=0
tempo_ready=false

while [ $elapsed -lt $timeout ]; do
  # Try multiple label selectors (Tempo Operator uses different labels in different versions)
  tempo_pods=""
  for label in "app.kubernetes.io/name=tempo" "app.kubernetes.io/instance=simplest" "tempo.grafana.com/name=simplest"; do
    tempo_pods=$(oc get pods -n ${NAMESPACE} -l "$label" --no-headers 2>/dev/null || true)
    if [ -n "$tempo_pods" ]; then
      break
    fi
  done
  
  # If no pods found by label, try by name pattern
  if [ -z "$tempo_pods" ]; then
    tempo_pods=$(oc get pods -n ${NAMESPACE} --no-headers 2>/dev/null | grep -E "^tempo-simplest|^simplest" || true)
  fi
  
  if [ -n "$tempo_pods" ]; then
    tempo_pods_count=$(echo "$tempo_pods" | wc -l | tr -d ' ')
    tempo_pods_count=${tempo_pods_count:-0}
    ready_pods_output=$(echo "$tempo_pods" | awk '{
      split($2, ready, "/");
      if ($3 == "Running" && ready[1] == ready[2] && ready[1] > 0) {
        print $0;
      }
    }')
    if [ -n "$ready_pods_output" ]; then
      ready_pods=$(echo "$ready_pods_output" | wc -l | tr -d ' ')
    else
      ready_pods=0
    fi
    ready_pods=${ready_pods:-0}
    
    if [ "$ready_pods" -gt 0 ]; then
      echo "✅ Tempo pods are running and ready ($ready_pods/$tempo_pods_count pod(s))"
      tempo_ready=true
      break
    else
      echo "⏳ Waiting for Tempo pods to be ready... ($tempo_pods_count pod(s) exist but not ready yet)"
    fi
  else
    echo "⏳ Waiting for Tempo pods to be created..."
  fi
  
  sleep 5
  elapsed=$((elapsed + 5))
done

if [ "$tempo_ready" = false ]; then
  echo "⚠️  Warning: Tempo may not be fully ready, but continuing with OpenTelemetry Collector deployment..."
fi

# Deploy OpenTelemetry Collector RBAC and CR (after Tempo is ready)
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
