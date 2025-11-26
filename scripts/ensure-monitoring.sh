#!/usr/bin/env bash
set -euo pipefail

#
# ensure-monitoring.sh - Idempotent monitoring stack setup
# This script ensures the monitoring stack is installed and ready.
# Safe to run multiple times.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-tempo-monitoring}"
PERF_TEST_NAMESPACE="${PERF_TEST_NAMESPACE:-tempo-perf-test}"
SA_NAME="monitoring-sa"
TIMEOUT="${TIMEOUT:-300}"  # 5 minutes timeout for readiness checks

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}✅${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠️${NC} $1"
}

log_error() {
    echo -e "${RED}❌${NC} $1"
}

log_wait() {
    echo -e "${YELLOW}⏳${NC} $1"
}

#
# Check prerequisites - verify required operators are installed
#
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if oc is available
    if ! command -v oc &> /dev/null; then
        log_error "oc CLI is not installed or not in PATH"
        exit 1
    fi
    
    # Check if logged into cluster
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    
    # Check if cluster-monitoring is available
    if ! oc get namespace openshift-monitoring &> /dev/null; then
        log_error "OpenShift monitoring stack not found. Cluster monitoring must be enabled."
        exit 1
    fi
    
    # Check if Grafana Operator CRD exists
    if ! oc get crd grafanas.grafana.integreatly.org &> /dev/null; then
        log_error "Grafana Operator is not installed. Please install the Grafana Operator first."
        log_error "You can install it from OperatorHub or run:"
        log_error "  oc apply -f https://operatorhub.io/install/grafana-operator.yaml"
        exit 1
    fi
    
    log_info "All prerequisites met."
}

#
# Enable user workload monitoring
#
setup_user_monitoring() {
    log_info "Enabling user workload monitoring..."
    
    # Check if the ConfigMap exists and patch/create accordingly
    if oc -n openshift-monitoring get configmap cluster-monitoring-config &> /dev/null; then
        # ConfigMap exists, check if user workload is already enabled
        current_config=$(oc -n openshift-monitoring get configmap cluster-monitoring-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
        if echo "$current_config" | grep -q "enableUserWorkload: true"; then
            log_info "User workload monitoring already enabled."
        else
            log_info "Patching cluster-monitoring-config to enable user workload monitoring..."
            oc -n openshift-monitoring patch configmap cluster-monitoring-config \
                --type=merge \
                -p '{"data":{"config.yaml":"enableUserWorkload: true"}}'
        fi
    else
        log_info "Creating cluster-monitoring-config ConfigMap..."
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    fi
}

#
# Create monitoring namespace and service account
#
setup_namespace_and_sa() {
    log_info "Setting up monitoring namespace and service account..."
    
    # Create namespace if not exists (idempotent)
    if ! oc get project "$MONITORING_NAMESPACE" &> /dev/null; then
        log_info "Creating project $MONITORING_NAMESPACE..."
        oc new-project "$MONITORING_NAMESPACE" || oc create namespace "$MONITORING_NAMESPACE"
    else
        log_info "Project $MONITORING_NAMESPACE already exists."
    fi
    
    # Create performance test namespace if not exists
    if ! oc get project "$PERF_TEST_NAMESPACE" &> /dev/null; then
        log_info "Creating project $PERF_TEST_NAMESPACE..."
        oc new-project "$PERF_TEST_NAMESPACE" || oc create namespace "$PERF_TEST_NAMESPACE"
    else
        log_info "Project $PERF_TEST_NAMESPACE already exists."
    fi
    
    # Create service account if not exists (idempotent)
    if ! oc get sa "$SA_NAME" -n "$MONITORING_NAMESPACE" &> /dev/null; then
        log_info "Creating service account $SA_NAME..."
        oc create sa "$SA_NAME" -n "$MONITORING_NAMESPACE"
    else
        log_info "Service account $SA_NAME already exists."
    fi
    
    # Add cluster-monitoring-view role (idempotent)
    log_info "Ensuring cluster-monitoring-view role binding..."
    oc adm policy add-cluster-role-to-user cluster-monitoring-view -z "$SA_NAME" -n "$MONITORING_NAMESPACE" 2>/dev/null || true
}

#
# Deploy Grafana and datasource
#
deploy_grafana() {
    log_info "Deploying Grafana..."
    
    # Generate a long-lived token for Prometheus access
    TOKEN=$(oc create token "$SA_NAME" --duration=8760h -n "$MONITORING_NAMESPACE")
    
    # Create Grafana credentials secret (idempotent via dry-run + apply)
    log_info "Creating Grafana credentials secret..."
    oc create secret generic credentials \
        --from-literal=GF_SECURITY_ADMIN_PASSWORD=grafana \
        --from-literal=GF_SECURITY_ADMIN_USER=root \
        --from-literal=PROMETHEUS_TOKEN="$TOKEN" \
        -n "$MONITORING_NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f -
    
    # Apply Grafana instance
    log_info "Applying Grafana instance..."
    oc apply -f "$PROJECT_ROOT/monitoring/manifests/grafana-instance.yaml" -n "$MONITORING_NAMESPACE"
    
    # Wait for Grafana service to be available
    log_wait "Waiting for Grafana service to be available..."
    local waited=0
    while ! oc get svc grafana-service -n "$MONITORING_NAMESPACE" &> /dev/null; do
        if [ $waited -ge $TIMEOUT ]; then
            log_error "Timeout waiting for Grafana service"
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log_info "Grafana service is available."
    
    # Create Grafana route (idempotent)
    log_info "Creating Grafana route..."
    oc create route edge grafana \
        --service=grafana-service \
        --insecure-policy=Redirect \
        -n "$MONITORING_NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f -
    
    # Create Prometheus datasource
    log_info "Creating Prometheus datasource..."
    cat <<EOF | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: grafana-ds
  namespace: ${MONITORING_NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc:9091
    isDefault: true
    jsonData:
      tlsSkipVerify: true
      timeInterval: "5s"
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: "Bearer ${TOKEN}"
    editable: true
EOF
    
    # Apply Tempo dashboard
    log_info "Applying Tempo dashboard..."
    oc apply -f "$PROJECT_ROOT/monitoring/manifests/tempo-dashboard.yaml" -n "$MONITORING_NAMESPACE"
}

#
# Wait for all monitoring components to be ready
#
wait_for_monitoring() {
    log_info "Waiting for monitoring components to be ready..."
    
    # Wait for user-workload prometheus pods
    log_wait "Waiting for user-workload Prometheus pods..."
    local waited=0
    while true; do
        ready_pods=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running") || ready_pods=0
        if [ "$ready_pods" -ge 1 ]; then
            log_info "User-workload Prometheus is ready ($ready_pods pods running)."
            break
        fi
        if [ $waited -ge $TIMEOUT ]; then
            log_error "Timeout waiting for user-workload Prometheus pods"
            exit 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    
    # Wait for Grafana deployment to be ready
    log_wait "Waiting for Grafana deployment to be ready..."
    waited=0
    while true; do
        ready=$(oc get deployment grafana-deployment -n "$MONITORING_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "$ready" -ge 1 ]; then
            log_info "Grafana deployment is ready ($ready replicas)."
            break
        fi
        if [ $waited -ge $TIMEOUT ]; then
            log_error "Timeout waiting for Grafana deployment"
            exit 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

#
# Verify Prometheus is healthy and can scrape metrics
#
verify_prometheus() {
    log_info "Verifying Prometheus health..."
    
    # Get thanos-querier route
    local thanos_url
    thanos_url=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "$thanos_url" ]; then
        log_warn "Could not get Thanos Querier route. Skipping health check."
        return 0
    fi
    
    # Simple health check - just verify we can reach Prometheus
    local token
    token=$(oc create token "$SA_NAME" -n "$MONITORING_NAMESPACE" --duration=1h 2>/dev/null || echo "")
    
    if [ -n "$token" ]; then
        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer $token" \
            "https://${thanos_url}/api/v1/query?query=up" 2>/dev/null || echo "000")
        
        if [ "$http_code" = "200" ]; then
            log_info "Prometheus is healthy and responding to queries."
        else
            log_warn "Prometheus returned HTTP $http_code. It may still be initializing."
        fi
    else
        log_warn "Could not create token for health check. Skipping."
    fi
}

#
# Print summary
#
print_summary() {
    echo ""
    echo "=============================================="
    log_info "Monitoring stack is ready!"
    echo "=============================================="
    echo ""
    
    local grafana_route
    grafana_route=$(oc get route grafana -n "$MONITORING_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "N/A")
    
    echo "Grafana URL: https://${grafana_route}"
    echo "Grafana Username: root"
    echo "Grafana Password: grafana"
    echo ""
    echo "Namespaces:"
    echo "  - Monitoring: $MONITORING_NAMESPACE"
    echo "  - Performance Tests: $PERF_TEST_NAMESPACE"
    echo ""
}

#
# Main execution
#
main() {
    echo "=============================================="
    echo "Tempo Performance Test - Monitoring Setup"
    echo "=============================================="
    echo ""
    
    check_prerequisites
    setup_user_monitoring
    setup_namespace_and_sa
    deploy_grafana
    wait_for_monitoring
    verify_prometheus
    print_summary
}

main "$@"

