#!/bin/bash

NAMESPACE=tempo-perf-test

if ! kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
  echo "Creating namespace $NAMESPACE..."
  kubectl create namespace "$NAMESPACE"
else
  echo "Namespace $NAMESPACE already exists. Continuing..."
fi

oc apply -f tempo/storate.yaml -n ${NAMESPACE}

kubectl apply -k tempo/test/small -n ${NAMESPACE}

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
