#!/usr/bin/env bash
set -euo pipefail

#
# collect-metrics.sh - Collect performance metrics from Prometheus
#
# Usage: ./collect-metrics.sh <load_name> <output_file>
#
# This script queries Prometheus for:
# - Query latencies (p50, p90, p99)
# - Resource utilization (CPU, memory)
# - Throughput (spans/second)
# - Error rates
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Configuration
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-tempo-monitoring}"
PERF_TEST_NAMESPACE="${PERF_TEST_NAMESPACE:-tempo-perf-test}"
SA_NAME="monitoring-sa"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}✅${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠️${NC} $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }

#
# Get Prometheus URL and token
#
get_prometheus_access() {
    # Get thanos-querier route
    PROMETHEUS_URL=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
    if [ -z "$PROMETHEUS_URL" ]; then
        log_error "Could not get Thanos Querier route"
        exit 1
    fi
    PROMETHEUS_URL="https://${PROMETHEUS_URL}"
    
    # Get token
    TOKEN=$(oc create token "$SA_NAME" -n "$MONITORING_NAMESPACE" --duration=1h 2>/dev/null)
    if [ -z "$TOKEN" ]; then
        log_error "Could not create token for Prometheus access"
        exit 1
    fi
}

#
# Execute a Prometheus query
#
prom_query() {
    local query="$1"
    local result
    
    result=$(curl -sk \
        -H "Authorization: Bearer $TOKEN" \
        --data-urlencode "query=${query}" \
        "${PROMETHEUS_URL}/api/v1/query" 2>/dev/null)
    
    echo "$result"
}

#
# Extract value from Prometheus response
#
extract_value() {
    local response="$1"
    local default="${2:-0}"
    
    local value
    value=$(echo "$response" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null)
    
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

#
# Collect query latency metrics
#
collect_query_latencies() {
    log_info "Collecting query latency metrics..."
    
    # P50 latency
    local p50_response
    p50_response=$(prom_query "histogram_quantile(0.50, sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_bucket[5m])) by (le))")
    P50_LATENCY=$(extract_value "$p50_response" "0")
    
    # P90 latency
    local p90_response
    p90_response=$(prom_query "histogram_quantile(0.90, sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_bucket[5m])) by (le))")
    P90_LATENCY=$(extract_value "$p90_response" "0")
    
    # P99 latency
    local p99_response
    p99_response=$(prom_query "histogram_quantile(0.99, sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_bucket[5m])) by (le))")
    P99_LATENCY=$(extract_value "$p99_response" "0")
    
    log_info "Query latencies - P50: ${P50_LATENCY}s, P90: ${P90_LATENCY}s, P99: ${P99_LATENCY}s"
}

#
# Collect resource utilization metrics
#
collect_resource_metrics() {
    log_info "Collecting resource utilization metrics..."
    
    # CPU usage (cores) for tempo pods
    local cpu_response
    cpu_response=$(prom_query "sum(rate(container_cpu_usage_seconds_total{namespace=\"${PERF_TEST_NAMESPACE}\", container=~\"tempo.*\"}[5m]))")
    AVG_CPU=$(extract_value "$cpu_response" "0")
    
    # Memory usage (bytes) for tempo pods
    local mem_response
    mem_response=$(prom_query "sum(container_memory_working_set_bytes{namespace=\"${PERF_TEST_NAMESPACE}\", container=~\"tempo.*\"})")
    MEM_BYTES=$(extract_value "$mem_response" "0")
    
    # Convert memory to GB
    if [ "$MEM_BYTES" != "0" ]; then
        MAX_MEMORY_GB=$(echo "scale=2; $MEM_BYTES / 1073741824" | bc 2>/dev/null || echo "0")
    else
        MAX_MEMORY_GB="0"
    fi
    
    log_info "Resources - CPU: ${AVG_CPU} cores, Memory: ${MAX_MEMORY_GB} GB"
}

#
# Collect throughput metrics
#
collect_throughput_metrics() {
    log_info "Collecting throughput metrics..."
    
    # Spans received per second
    local spans_response
    spans_response=$(prom_query "sum(rate(tempo_distributor_spans_received_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[5m]))")
    SPANS_PER_SEC=$(extract_value "$spans_response" "0")
    
    # Bytes received per second
    local bytes_response
    bytes_response=$(prom_query "sum(rate(tempo_distributor_bytes_received_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[5m]))")
    BYTES_PER_SEC=$(extract_value "$bytes_response" "0")
    
    log_info "Throughput - Spans/sec: ${SPANS_PER_SEC}, Bytes/sec: ${BYTES_PER_SEC}"
}

#
# Collect error metrics
#
collect_error_metrics() {
    log_info "Collecting error metrics..."
    
    # Query failures
    local failures_response
    failures_response=$(prom_query "sum(rate(query_failures_count_${PERF_TEST_NAMESPACE//-/_}[5m]))")
    QUERY_FAILURES=$(extract_value "$failures_response" "0")
    
    # Total queries for error rate calculation
    local total_response
    total_response=$(prom_query "sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_count[5m]))")
    TOTAL_QUERIES=$(extract_value "$total_response" "0")
    
    # Calculate error rate
    if [ "$TOTAL_QUERIES" != "0" ] && [ "$(echo "$TOTAL_QUERIES > 0" | bc 2>/dev/null || echo "0")" = "1" ]; then
        ERROR_RATE=$(echo "scale=4; $QUERY_FAILURES / $TOTAL_QUERIES * 100" | bc 2>/dev/null || echo "0")
    else
        ERROR_RATE="0"
    fi
    
    # Dropped spans
    local dropped_response
    dropped_response=$(prom_query "sum(rate(tempo_distributor_spans_dropped_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[5m]))")
    DROPPED_SPANS=$(extract_value "$dropped_response" "0")
    
    log_info "Errors - Query failures/sec: ${QUERY_FAILURES}, Error rate: ${ERROR_RATE}%, Dropped spans/sec: ${DROPPED_SPANS}"
}

#
# Write metrics to JSON file
#
write_metrics_json() {
    local load_name="$1"
    local output_file="$2"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat > "$output_file" <<EOF
{
  "timestamp": "${timestamp}",
  "load_name": "${load_name}",
  "metrics": {
    "query_latencies": {
      "p50_seconds": ${P50_LATENCY:-0},
      "p90_seconds": ${P90_LATENCY:-0},
      "p99_seconds": ${P99_LATENCY:-0}
    },
    "resources": {
      "avg_cpu_cores": ${AVG_CPU:-0},
      "max_memory_gb": ${MAX_MEMORY_GB:-0}
    },
    "throughput": {
      "spans_per_second": ${SPANS_PER_SEC:-0},
      "bytes_per_second": ${BYTES_PER_SEC:-0}
    },
    "errors": {
      "query_failures_per_second": ${QUERY_FAILURES:-0},
      "error_rate_percent": ${ERROR_RATE:-0},
      "dropped_spans_per_second": ${DROPPED_SPANS:-0}
    }
  }
}
EOF
    
    log_info "Metrics written to: $output_file"
}

#
# Main
#
main() {
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <load_name> <output_file>"
        echo ""
        echo "Example: $0 medium results/raw/medium.json"
        exit 1
    fi
    
    local load_name="$1"
    local output_file="$2"
    
    # Create output directory if needed
    mkdir -p "$(dirname "$output_file")"
    
    echo "=============================================="
    echo "Collecting metrics for load: $load_name"
    echo "=============================================="
    echo ""
    
    # Initialize metrics variables
    P50_LATENCY="0"
    P90_LATENCY="0"
    P99_LATENCY="0"
    AVG_CPU="0"
    MAX_MEMORY_GB="0"
    SPANS_PER_SEC="0"
    BYTES_PER_SEC="0"
    QUERY_FAILURES="0"
    ERROR_RATE="0"
    DROPPED_SPANS="0"
    TOTAL_QUERIES="0"
    
    get_prometheus_access
    collect_query_latencies
    collect_resource_metrics
    collect_throughput_metrics
    collect_error_metrics
    write_metrics_json "$load_name" "$output_file"
    
    echo ""
    log_info "Metrics collection complete!"
}

main "$@"

