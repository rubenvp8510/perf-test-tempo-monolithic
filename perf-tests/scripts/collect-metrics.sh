#!/usr/bin/env bash
set -euo pipefail

#
# collect-metrics.sh - Collect performance metrics from Prometheus
#
# Usage: ./collect-metrics.sh <load_name> <output_file> [duration_minutes]
#
# This script queries Prometheus for:
# - Query latencies (p50, p90, p99)
# - Resource utilization (CPU, memory)
# - Throughput (spans/second)
# - Error rates
#
# Uses range queries to collect per-minute time-series data.
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
# Execute a Prometheus instant query
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
# Execute a Prometheus range query (returns time-series data)
#
prom_range_query() {
    local query="$1"
    local start="$2"
    local end="$3"
    local step="${4:-60}"  # Default 1 minute step
    local result
    
    result=$(curl -sk \
        -H "Authorization: Bearer $TOKEN" \
        --data-urlencode "query=${query}" \
        --data-urlencode "start=${start}" \
        --data-urlencode "end=${end}" \
        --data-urlencode "step=${step}" \
        "${PROMETHEUS_URL}/api/v1/query_range" 2>/dev/null)
    
    echo "$result"
}

#
# Extract time-series values from Prometheus range query response
# Returns JSON array of {timestamp, value} objects
#
extract_timeseries() {
    local response="$1"
    
    echo "$response" | jq -r '
        .data.result[0].values // [] | 
        map({timestamp: .[0], value: (.[1] | tonumber)})
    ' 2>/dev/null || echo "[]"
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
# Calculate adaptive rate window based on test duration
# For short tests (≤10 minutes), use 1m window; for longer tests, use 5m window
#
get_rate_window() {
    local duration_minutes="$1"
    
    # Default to 5m if duration not provided
    if [ -z "$duration_minutes" ] || [ "$duration_minutes" = "0" ]; then
        echo "5m"
        return
    fi
    
    # Use 1m window for tests ≤ 10 minutes, 5m for longer tests
    if [ "$(echo "$duration_minutes <= 10" | bc 2>/dev/null || echo "0")" = "1" ]; then
        echo "1m"
    else
        echo "5m"
    fi
}

#
# Collect query latency metrics
#
collect_query_latencies() {
    local duration_minutes="${1:-30}"
    local rate_window
    rate_window=$(get_rate_window "$duration_minutes")
    
    log_info "Collecting query latency metrics (using ${rate_window} rate window for ${duration_minutes}min test)..."
    
    # P50 latency
    local p50_response
    p50_response=$(prom_query "histogram_quantile(0.50, sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_bucket[${rate_window}])) by (le))")
    P50_LATENCY=$(extract_value "$p50_response" "0")
    
    # P90 latency
    local p90_response
    p90_response=$(prom_query "histogram_quantile(0.90, sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_bucket[${rate_window}])) by (le))")
    P90_LATENCY=$(extract_value "$p90_response" "0")
    
    # P99 latency
    local p99_response
    p99_response=$(prom_query "histogram_quantile(0.99, sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_bucket[${rate_window}])) by (le))")
    P99_LATENCY=$(extract_value "$p99_response" "0")
    
    # Average latency (mean) - calculated from sum/count
    local avg_sum_response avg_count_response
    avg_sum_response=$(prom_query "sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_sum[${rate_window}]))")
    avg_count_response=$(prom_query "sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_count[${rate_window}]))")
    
    local avg_sum avg_count
    avg_sum=$(extract_value "$avg_sum_response" "0")
    avg_count=$(extract_value "$avg_count_response" "0")
    
    if [ "$(echo "$avg_count > 0" | bc 2>/dev/null || echo "0")" = "1" ]; then
        AVG_LATENCY=$(echo "scale=6; $avg_sum / $avg_count" | bc 2>/dev/null || echo "0")
    else
        AVG_LATENCY="0"
    fi
    
    log_info "Query latencies - P50: ${P50_LATENCY}s, P90: ${P90_LATENCY}s, P99: ${P99_LATENCY}s, Avg: ${AVG_LATENCY}s"
}

#
# Collect resource utilization metrics
#
collect_resource_metrics() {
    local duration_minutes="${1:-30}"
    
    log_info "Collecting resource utilization metrics over ${duration_minutes} minute test range..."
    
    # Calculate test time range (same as collect_timeseries_data)
    local end_time start_time
    end_time=$(date +%s)
    start_time=$((end_time - duration_minutes * 60))
    
    # CPU time-series using range query
    local cpu_response
    cpu_response=$(prom_range_query \
        "sum(rate(container_cpu_usage_seconds_total{namespace=\"${PERF_TEST_NAMESPACE}\", container=~\"tempo.*\"}[5m]))" \
        "$start_time" "$end_time" "60")
    
    # Extract CPU stats (avg, max, min) from time-series
    local cpu_stats
    cpu_stats=$(echo "$cpu_response" | jq -r '
        .data.result[0].values // [] | 
        map(.[1] | tonumber) | 
        if length > 0 then {
            avg: (add / length),
            max: max,
            min: min
        } else {
            avg: 0, max: 0, min: 0
        } end
    ')
    AVG_CPU=$(echo "$cpu_stats" | jq -r '.avg')
    MAX_CPU=$(echo "$cpu_stats" | jq -r '.max')
    MIN_CPU=$(echo "$cpu_stats" | jq -r '.min')
    
    # Memory time-series using range query
    local mem_response
    mem_response=$(prom_range_query \
        "sum(container_memory_working_set_bytes{namespace=\"${PERF_TEST_NAMESPACE}\", container=~\"tempo.*\"})" \
        "$start_time" "$end_time" "60")
    
    # Extract Memory stats (avg, max, min) from time-series, convert to GB
    local mem_stats
    mem_stats=$(echo "$mem_response" | jq -r '
        .data.result[0].values // [] | 
        map((.[1] | tonumber) / 1073741824) | 
        if length > 0 then {
            avg: (add / length),
            max: max,
            min: min
        } else {
            avg: 0, max: 0, min: 0
        } end
    ')
    AVG_MEMORY_GB=$(echo "$mem_stats" | jq -r '.avg')
    MAX_MEMORY_GB=$(echo "$mem_stats" | jq -r '.max')
    MIN_MEMORY_GB=$(echo "$mem_stats" | jq -r '.min')
    
    log_info "Resources - CPU: Avg=${AVG_CPU}, Max=${MAX_CPU}, Min=${MIN_CPU} cores"
    log_info "Resources - Memory: Avg=${AVG_MEMORY_GB}, Max=${MAX_MEMORY_GB}, Min=${MIN_MEMORY_GB} GB"
}

#
# Collect throughput metrics
#
collect_throughput_metrics() {
    local duration_minutes="${1:-30}"
    local rate_window
    rate_window=$(get_rate_window "$duration_minutes")
    
    log_info "Collecting throughput metrics (using ${rate_window} rate window)..."
    
    # Spans received per second
    local spans_response
    spans_response=$(prom_query "sum(rate(tempo_distributor_spans_received_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[${rate_window}]))")
    SPANS_PER_SEC=$(extract_value "$spans_response" "0")
    
    # Bytes received per second
    local bytes_response
    bytes_response=$(prom_query "sum(rate(tempo_distributor_bytes_received_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[${rate_window}]))")
    BYTES_PER_SEC=$(extract_value "$bytes_response" "0")
    
    log_info "Throughput - Spans/sec: ${SPANS_PER_SEC}, Bytes/sec: ${BYTES_PER_SEC}"
}

#
# Collect error metrics
#
collect_error_metrics() {
    local duration_minutes="${1:-30}"
    local rate_window
    rate_window=$(get_rate_window "$duration_minutes")
    
    log_info "Collecting error metrics (using ${rate_window} rate window)..."
    
    # Query failures
    local failures_response
    failures_response=$(prom_query "sum(rate(query_failures_count_${PERF_TEST_NAMESPACE//-/_}[${rate_window}]))")
    QUERY_FAILURES=$(extract_value "$failures_response" "0")
    
    # Total queries for error rate calculation (this is also actual QPS)
    local total_response
    total_response=$(prom_query "sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_count[${rate_window}]))")
    TOTAL_QUERIES=$(extract_value "$total_response" "0")
    
    # Store actual QPS (same as total queries rate)
    ACTUAL_QPS="$TOTAL_QUERIES"
    
    # Calculate error rate
    if [ "$TOTAL_QUERIES" != "0" ] && [ "$(echo "$TOTAL_QUERIES > 0" | bc 2>/dev/null || echo "0")" = "1" ]; then
        ERROR_RATE=$(echo "scale=4; $QUERY_FAILURES / $TOTAL_QUERIES * 100" | bc 2>/dev/null || echo "0")
    else
        ERROR_RATE="0"
    fi
    
    # Dropped spans
    local dropped_response
    dropped_response=$(prom_query "sum(rate(tempo_distributor_spans_dropped_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[${rate_window}]))")
    DROPPED_SPANS=$(extract_value "$dropped_response" "0")
    
    # Discarded spans
    local discarded_response
    discarded_response=$(prom_query "sum(rate(tempo_discarded_spans_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[${rate_window}]))")
    DISCARDED_SPANS=$(extract_value "$discarded_response" "0")
    
    log_info "Errors - Query failures/sec: ${QUERY_FAILURES}, Error rate: ${ERROR_RATE}%, Dropped spans/sec: ${DROPPED_SPANS}, Discarded spans/sec: ${DISCARDED_SPANS}"
    log_info "Actual QPS: ${ACTUAL_QPS}"
}

#
# Collect spans returned metrics (from query results)
#
collect_spans_returned_metrics() {
    local duration_minutes="${1:-30}"
    local rate_window
    rate_window=$(get_rate_window "$duration_minutes")
    
    log_info "Collecting spans returned metrics (using ${rate_window} rate window)..."
    
    # Average spans returned per query (sum/count from histogram)
    local sum_response count_response
    sum_response=$(prom_query "sum(rate(query_load_test_spans_returned_${PERF_TEST_NAMESPACE//-/_}_sum[${rate_window}]))")
    count_response=$(prom_query "sum(rate(query_load_test_spans_returned_${PERF_TEST_NAMESPACE//-/_}_count[${rate_window}]))")
    
    local sum_val count_val
    sum_val=$(extract_value "$sum_response" "0")
    count_val=$(extract_value "$count_response" "0")
    
    # Calculate average (sum/count)
    if [ "$count_val" != "0" ] && [ "$(echo "$count_val > 0" | bc 2>/dev/null || echo "0")" = "1" ]; then
        AVG_SPANS_RETURNED=$(echo "scale=2; $sum_val / $count_val" | bc 2>/dev/null || echo "0")
    else
        AVG_SPANS_RETURNED="0"
    fi
    
    log_info "Average spans returned per query: ${AVG_SPANS_RETURNED}"
}

#
# Collect time-series data using range queries (1-minute granularity)
#
collect_timeseries_data() {
    local duration_minutes="$1"
    
    log_info "Collecting time-series data (${duration_minutes} minutes, 1-minute intervals)..."
    
    local end_time start_time
    end_time=$(date +%s)
    start_time=$((end_time - duration_minutes * 60))
    
    # CPU time-series (use 5m rate window for reliability - 1m can miss samples)
    local cpu_response
    cpu_response=$(prom_range_query \
        "sum(rate(container_cpu_usage_seconds_total{namespace=\"${PERF_TEST_NAMESPACE}\", container=~\"tempo.*\"}[5m]))" \
        "$start_time" "$end_time" "60")
    TS_CPU=$(extract_timeseries "$cpu_response")
    
    # Memory time-series (convert to GB in jq)
    local mem_response
    mem_response=$(prom_range_query \
        "sum(container_memory_working_set_bytes{namespace=\"${PERF_TEST_NAMESPACE}\", container=~\"tempo.*\"})" \
        "$start_time" "$end_time" "60")
    TS_MEMORY=$(echo "$mem_response" | jq -r '
        .data.result[0].values // [] | 
        map({timestamp: .[0], value: ((.[1] | tonumber) / 1073741824)})
    ' 2>/dev/null || echo "[]")
    
    # Spans/sec time-series
    local spans_response
    spans_response=$(prom_range_query \
        "sum(rate(tempo_distributor_spans_received_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[1m]))" \
        "$start_time" "$end_time" "60")
    TS_SPANS=$(extract_timeseries "$spans_response")
    
    # Bytes/sec time-series
    local bytes_response
    bytes_response=$(prom_range_query \
        "sum(rate(tempo_distributor_bytes_received_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[1m]))" \
        "$start_time" "$end_time" "60")
    TS_BYTES=$(extract_timeseries "$bytes_response")
    
    # P50 latency time-series
    local p50_response
    p50_response=$(prom_range_query \
        "histogram_quantile(0.50, sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_bucket[1m])) by (le))" \
        "$start_time" "$end_time" "60")
    TS_P50=$(extract_timeseries "$p50_response")
    
    # P90 latency time-series
    local p90_response
    p90_response=$(prom_range_query \
        "histogram_quantile(0.90, sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_bucket[1m])) by (le))" \
        "$start_time" "$end_time" "60")
    TS_P90=$(extract_timeseries "$p90_response")
    
    # P99 latency time-series
    local p99_response
    p99_response=$(prom_range_query \
        "histogram_quantile(0.99, sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_bucket[1m])) by (le))" \
        "$start_time" "$end_time" "60")
    TS_P99=$(extract_timeseries "$p99_response")
    
    # Query failures time-series
    local failures_response
    failures_response=$(prom_range_query \
        "sum(rate(query_failures_count_${PERF_TEST_NAMESPACE//-/_}[1m]))" \
        "$start_time" "$end_time" "60")
    TS_FAILURES=$(extract_timeseries "$failures_response")
    
    # Dropped spans time-series
    local dropped_response
    dropped_response=$(prom_range_query \
        "sum(rate(tempo_distributor_spans_dropped_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[1m]))" \
        "$start_time" "$end_time" "60")
    TS_DROPPED=$(extract_timeseries "$dropped_response")
    
    # Discarded spans time-series
    local discarded_response
    discarded_response=$(prom_range_query \
        "sum(rate(tempo_discarded_spans_total{namespace=\"${PERF_TEST_NAMESPACE}\"}[1m]))" \
        "$start_time" "$end_time" "60")
    TS_DISCARDED=$(extract_timeseries "$discarded_response")
    
    # Average spans returned per query time-series (sum/count from histogram)
    local spans_ret_sum_response spans_ret_count_response
    spans_ret_sum_response=$(prom_range_query \
        "sum(rate(query_load_test_spans_returned_${PERF_TEST_NAMESPACE//-/_}_sum[1m]))" \
        "$start_time" "$end_time" "60")
    spans_ret_count_response=$(prom_range_query \
        "sum(rate(query_load_test_spans_returned_${PERF_TEST_NAMESPACE//-/_}_count[1m]))" \
        "$start_time" "$end_time" "60")
    
    # Calculate average per timestamp using jq
    local sum_ts count_ts
    sum_ts=$(extract_timeseries "$spans_ret_sum_response")
    count_ts=$(extract_timeseries "$spans_ret_count_response")
    
    TS_SPANS_RETURNED=$(jq -n \
        --argjson sum_ts "$sum_ts" \
        --argjson count_ts "$count_ts" \
        '[range(0; ($sum_ts | length))] | map({
            timestamp: $sum_ts[.].timestamp,
            value: (if $count_ts[.].value > 0 then ($sum_ts[.].value / $count_ts[.].value) else 0 end)
        })' 2>/dev/null || echo "[]")
    
    # QPS (queries per second) time-series - rate of queries executed
    local qps_response
    qps_response=$(prom_range_query \
        "sum(rate(query_load_test_${PERF_TEST_NAMESPACE//-/_}_count[1m]))" \
        "$start_time" "$end_time" "60")
    TS_QPS=$(extract_timeseries "$qps_response")
    
    local sample_count
    sample_count=$(echo "$TS_CPU" | jq 'length' 2>/dev/null || echo "0")
    log_info "Collected $sample_count time-series data points"
}

#
# Collect per-container time-series data (CPU and memory per container)
#
collect_per_container_timeseries() {
    local duration_minutes="$1"
    
    log_info "Collecting per-container time-series data (${duration_minutes} minutes, 1-minute intervals)..."
    
    local end_time start_time
    end_time=$(date +%s)
    start_time=$((end_time - duration_minutes * 60))
    
    # CPU time-series per container (without sum aggregation)
    local cpu_response
    cpu_response=$(prom_range_query \
        "rate(container_cpu_usage_seconds_total{namespace=\"${PERF_TEST_NAMESPACE}\", container=~\"tempo.*\"}[5m])" \
        "$start_time" "$end_time" "60")
    
    # Extract per-container CPU data (group by container name)
    TS_CPU_PER_CONTAINER=$(echo "$cpu_response" | jq -r '
        .data.result // [] | 
        map({
            container: (.metric.container // "unknown"),
            pod: (.metric.pod // "unknown"),
            values: (.values // [] | map({timestamp: .[0], value: (.[1] | tonumber)}))
        })
    ' 2>/dev/null || echo "[]")
    
    # Memory time-series per container (without sum aggregation)
    local mem_response
    mem_response=$(prom_range_query \
        "container_memory_working_set_bytes{namespace=\"${PERF_TEST_NAMESPACE}\", container=~\"tempo.*\"}" \
        "$start_time" "$end_time" "60")
    
    # Extract per-container memory data (convert to GB)
    TS_MEMORY_PER_CONTAINER=$(echo "$mem_response" | jq -r '
        .data.result // [] | 
        map({
            container: (.metric.container // "unknown"),
            pod: (.metric.pod // "unknown"),
            values: (.values // [] | map({timestamp: .[0], value: ((.[1] | tonumber) / 1073741824)}))
        })
    ' 2>/dev/null || echo "[]")
    
    local container_count
    container_count=$(echo "$TS_CPU_PER_CONTAINER" | jq 'length' 2>/dev/null || echo "0")
    log_info "Collected per-container data for $container_count container(s)"
}

#
# Calculate resource recommendations with safety margin
#
calculate_resource_recommendations() {
    log_info "Calculating resource recommendations (20% safety margin)..."
    
    # Peak memory from time-series (maximum value observed)
    if [ "$TS_MEMORY" != "[]" ] && [ -n "$TS_MEMORY" ]; then
        PEAK_MEMORY_GB=$(echo "$TS_MEMORY" | jq '[.[].value] | max' 2>/dev/null || echo "0")
    else
        PEAK_MEMORY_GB="$MAX_MEMORY_GB"
    fi
    
    # Sustained CPU: use 95th percentile of the stable period
    # Exclude first 20% (ramp-up) and last 20% (ramp-down) to get peak sustained load
    if [ "$TS_CPU" != "[]" ] && [ -n "$TS_CPU" ]; then
        SUSTAINED_CPU=$(echo "$TS_CPU" | jq '
            . as $arr | 
            ($arr | length) as $len |
            if $len > 5 then
                # Skip first 20% and last 20% to focus on stable period
                ($len * 0.2 | floor) as $skip_start |
                ($len * 0.8 | floor) as $end |
                $arr[$skip_start:$end] | [.[].value] | sort | 
                # 95th percentile of the stable period
                .[((length * 0.95) | floor)]
            else
                # For short tests, just use 95th percentile of all data
                [.[].value] | sort | .[((length * 0.95) | floor)]
            end
        ' 2>/dev/null || echo "$AVG_CPU")
    else
        SUSTAINED_CPU="$AVG_CPU"
    fi
    
    # Calculate recommendations with 20% safety margin
    RECOMMENDED_CPU=$(echo "scale=3; $SUSTAINED_CPU * 1.20" | bc 2>/dev/null || echo "0")
    RECOMMENDED_MEMORY_GB=$(echo "scale=3; $PEAK_MEMORY_GB * 1.20" | bc 2>/dev/null || echo "0")
    
    # Round up CPU to nearest 100m (0.1 cores)
    RECOMMENDED_CPU=$(echo "scale=1; x=$RECOMMENDED_CPU * 10; scale=0; x=x+0.9; x/=1; scale=1; x/10" | bc 2>/dev/null || echo "0.1")
    
    # Round up memory to nearest 0.5 GB
    RECOMMENDED_MEMORY_GB=$(echo "scale=1; x=$RECOMMENDED_MEMORY_GB * 2; scale=0; x=x+0.9; x/=1; scale=1; x/2" | bc 2>/dev/null || echo "0.5")
    
    log_info "Peak Memory: ${PEAK_MEMORY_GB} GB, Sustained CPU (p95 stable): ${SUSTAINED_CPU} cores"
    log_info "Recommended (with 20% margin) - CPU: ${RECOMMENDED_CPU} cores, Memory: ${RECOMMENDED_MEMORY_GB} GB"
}

#
# Write metrics to JSON file (includes time-series data)
#
write_metrics_json() {
    local load_name="$1"
    local output_file="$2"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Build JSON with jq to properly handle time-series arrays
    jq -n \
        --arg timestamp "$timestamp" \
        --arg load_name "$load_name" \
        --argjson p50 "${P50_LATENCY:-0}" \
        --argjson p90 "${P90_LATENCY:-0}" \
        --argjson p99 "${P99_LATENCY:-0}" \
        --argjson avg_latency "${AVG_LATENCY:-0}" \
        --argjson cpu "${AVG_CPU:-0}" \
        --argjson max_cpu "${MAX_CPU:-0}" \
        --argjson min_cpu "${MIN_CPU:-0}" \
        --argjson avg_mem "${AVG_MEMORY_GB:-0}" \
        --argjson max_mem "${MAX_MEMORY_GB:-0}" \
        --argjson min_mem "${MIN_MEMORY_GB:-0}" \
        --argjson sustained_cpu "${SUSTAINED_CPU:-0}" \
        --argjson peak_memory "${PEAK_MEMORY_GB:-0}" \
        --argjson recommended_cpu "${RECOMMENDED_CPU:-0}" \
        --argjson recommended_memory "${RECOMMENDED_MEMORY_GB:-0}" \
        --argjson spans "${SPANS_PER_SEC:-0}" \
        --argjson bytes "${BYTES_PER_SEC:-0}" \
        --argjson failures "${QUERY_FAILURES:-0}" \
        --argjson error_rate "${ERROR_RATE:-0}" \
        --argjson dropped "${DROPPED_SPANS:-0}" \
        --argjson discarded "${DISCARDED_SPANS:-0}" \
        --argjson avg_spans_returned "${AVG_SPANS_RETURNED:-0}" \
        --argjson actual_qps "${ACTUAL_QPS:-0}" \
        --argjson ts_cpu "${TS_CPU:-[]}" \
        --argjson ts_memory "${TS_MEMORY:-[]}" \
        --argjson ts_spans "${TS_SPANS:-[]}" \
        --argjson ts_bytes "${TS_BYTES:-[]}" \
        --argjson ts_p50 "${TS_P50:-[]}" \
        --argjson ts_p90 "${TS_P90:-[]}" \
        --argjson ts_p99 "${TS_P99:-[]}" \
        --argjson ts_failures "${TS_FAILURES:-[]}" \
        --argjson ts_dropped "${TS_DROPPED:-[]}" \
        --argjson ts_discarded "${TS_DISCARDED:-[]}" \
        --argjson ts_spans_returned "${TS_SPANS_RETURNED:-[]}" \
        --argjson ts_qps "${TS_QPS:-[]}" \
        --argjson ts_cpu_per_container "${TS_CPU_PER_CONTAINER:-[]}" \
        --argjson ts_memory_per_container "${TS_MEMORY_PER_CONTAINER:-[]}" \
        '{
          timestamp: $timestamp,
          load_name: $load_name,
          metrics: {
            query_latencies: {
              p50_seconds: $p50,
              p90_seconds: $p90,
              p99_seconds: $p99,
              avg_seconds: $avg_latency
            },
            resources: {
              avg_cpu_cores: $cpu,
              max_cpu_cores: $max_cpu,
              min_cpu_cores: $min_cpu,
              avg_memory_gb: $avg_mem,
              max_memory_gb: $max_mem,
              min_memory_gb: $min_mem,
              sustained_cpu_cores: $sustained_cpu,
              peak_memory_gb: $peak_memory
            },
            resource_recommendations: {
              safety_margin_percent: 20,
              cpu_cores: $recommended_cpu,
              memory_gb: $recommended_memory
            },
            throughput: {
              spans_per_second: $spans,
              bytes_per_second: $bytes
            },
            errors: {
              query_failures_per_second: $failures,
              error_rate_percent: $error_rate,
              dropped_spans_per_second: $dropped,
              discarded_spans_per_second: $discarded
            },
            query_results: {
              avg_spans_returned: $avg_spans_returned,
              actual_qps: $actual_qps
            }
          },
          timeseries: {
            interval_seconds: 60,
            cpu_cores: $ts_cpu,
            memory_gb: $ts_memory,
            spans_per_second: $ts_spans,
            bytes_per_second: $ts_bytes,
            p50_latency_seconds: $ts_p50,
            p90_latency_seconds: $ts_p90,
            p99_latency_seconds: $ts_p99,
            query_failures_per_second: $ts_failures,
            dropped_spans_per_second: $ts_dropped,
            discarded_spans_per_second: $ts_discarded,
            avg_spans_returned: $ts_spans_returned,
            qps: $ts_qps
          },
          per_container: {
            cpu_cores: $ts_cpu_per_container,
            memory_gb: $ts_memory_per_container
          }
        }' > "$output_file"
    
    log_info "Metrics written to: $output_file"
}

#
# Main
#
main() {
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <load_name> <output_file> [duration_minutes]"
        echo ""
        echo "Example: $0 medium results/raw/medium.json 30"
        echo ""
        echo "Arguments:"
        echo "  load_name         Name of the load test"
        echo "  output_file       Path to output JSON file"
        echo "  duration_minutes  Duration to query for time-series data (default: 30)"
        exit 1
    fi
    
    local load_name="$1"
    local output_file="$2"
    local duration_minutes="${3:-30}"
    
    # Create output directory if needed
    mkdir -p "$(dirname "$output_file")"
    
    echo "=============================================="
    echo "Collecting metrics for load: $load_name"
    echo "Time-series range: ${duration_minutes} minutes"
    echo "=============================================="
    echo ""
    
    # Initialize metrics variables
    P50_LATENCY="0"
    P90_LATENCY="0"
    P99_LATENCY="0"
    AVG_LATENCY="0"
    AVG_CPU="0"
    MAX_CPU="0"
    MIN_CPU="0"
    AVG_MEMORY_GB="0"
    MAX_MEMORY_GB="0"
    MIN_MEMORY_GB="0"
    SUSTAINED_CPU="0"
    PEAK_MEMORY_GB="0"
    RECOMMENDED_CPU="0"
    RECOMMENDED_MEMORY_GB="0"
    SPANS_PER_SEC="0"
    BYTES_PER_SEC="0"
    QUERY_FAILURES="0"
    ERROR_RATE="0"
    DROPPED_SPANS="0"
    DISCARDED_SPANS="0"
    TOTAL_QUERIES="0"
    AVG_SPANS_RETURNED="0"
    ACTUAL_QPS="0"
    
    # Initialize time-series variables
    TS_CPU="[]"
    TS_MEMORY="[]"
    TS_SPANS="[]"
    TS_BYTES="[]"
    TS_P50="[]"
    TS_P90="[]"
    TS_P99="[]"
    TS_FAILURES="[]"
    TS_DROPPED="[]"
    TS_DISCARDED="[]"
    TS_SPANS_RETURNED="[]"
    TS_CPU_PER_CONTAINER="[]"
    TS_MEMORY_PER_CONTAINER="[]"
    TS_QPS="[]"
    
    get_prometheus_access
    collect_query_latencies "$duration_minutes"
    collect_resource_metrics "$duration_minutes"
    collect_throughput_metrics "$duration_minutes"
    collect_error_metrics "$duration_minutes"
    collect_spans_returned_metrics "$duration_minutes"
    collect_timeseries_data "$duration_minutes"
    collect_per_container_timeseries "$duration_minutes"
    calculate_resource_recommendations
    write_metrics_json "$load_name" "$output_file"
    
    echo ""
    log_info "Metrics collection complete!"
}

main "$@"

