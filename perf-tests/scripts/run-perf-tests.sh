#!/usr/bin/env bash
set -euo pipefail

#
# run-perf-tests.sh - Main performance test orchestrator
#
# Usage: ./run-perf-tests.sh [options]
#
# Options:
#   -c, --config <file>     Config file (default: config/loads.yaml)
#   -d, --duration <time>   Override test duration (e.g., 30m, 1h)
#   -l, --load <name>       Run only specific load (can be repeated)
#   -s, --skip-monitoring   Skip monitoring setup
#   -k, --keep-generators   Don't cleanup generators between tests
#   -f, --fresh             Recreate Tempo with clean state before each test
#   -h, --help              Show this help message
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF_TESTS_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$PERF_TESTS_DIR")"

# Default configuration
CONFIG_FILE="${PERF_TESTS_DIR}/config/loads.yaml"
RESULTS_DIR="${PERF_TESTS_DIR}/results"
TEMPLATES_DIR="${PERF_TESTS_DIR}/templates"
DURATION_OVERRIDE=""
SPECIFIC_LOADS=()
SKIP_MONITORING=false
KEEP_GENERATORS=false
FRESH_STATE=false

# Namespace configuration
PERF_TEST_NAMESPACE="tempo-perf-test"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}✅${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠️${NC} $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }
log_wait() { echo -e "${YELLOW}⏳${NC} $1"; }
log_section() { echo -e "\n${BLUE}══════════════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════════════${NC}\n"; }

#
# Show help
#
show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Performance test orchestrator for Tempo Monolithic.

Options:
  -c, --config <file>     Config file (default: config/loads.yaml)
  -d, --duration <time>   Override test duration (e.g., 30m, 1h)
  -l, --load <name>       Run only specific load (can be repeated)
  -s, --skip-monitoring   Skip monitoring setup check
  -k, --keep-generators   Don't cleanup generators between tests
  -f, --fresh             Recreate Tempo with clean state before each test
  -h, --help              Show this help message

Examples:
  $(basename "$0")                          # Run all loads with defaults
  $(basename "$0") -d 15m                   # Run all loads for 15 minutes each
  $(basename "$0") -l low -l medium         # Run only 'low' and 'medium' loads
  $(basename "$0") -s -d 5m -l low          # Quick test, skip monitoring check

EOF
    exit 0
}

#
# Parse command line arguments
#
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -d|--duration)
                DURATION_OVERRIDE="$2"
                shift 2
                ;;
            -l|--load)
                SPECIFIC_LOADS+=("$2")
                shift 2
                ;;
            -s|--skip-monitoring)
                SKIP_MONITORING=true
                shift
                ;;
            -k|--keep-generators)
                KEEP_GENERATORS=true
                shift
                ;;
            -f|--fresh)
                FRESH_STATE=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                ;;
        esac
    done
}

#
# Check prerequisites
#
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check required tools
    local missing=()
    for tool in oc jq yq bc; do
        if ! command -v "$tool" &> /dev/null; then
            missing+=("$tool")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them before running the tests."
        exit 1
    fi
    
    # Check OpenShift login
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    
    # Check config file
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Check Tempo Operator
    if ! oc get crd tempomonolithics.tempo.grafana.com &> /dev/null; then
        log_error "Tempo Operator is not installed. Please install it first."
        exit 1
    fi
    
    # Check OpenTelemetry Operator
    if ! oc get crd opentelemetrycollectors.opentelemetry.io &> /dev/null; then
        log_error "OpenTelemetry Operator is not installed. Please install it from OperatorHub."
        exit 1
    fi
    
    log_info "All prerequisites met."
}

#
# Ensure monitoring is ready
#
ensure_monitoring() {
    if [ "$SKIP_MONITORING" = true ]; then
        log_warn "Skipping monitoring setup (--skip-monitoring flag)"
        return 0
    fi
    
    log_section "Setting Up Monitoring"
    
    "${PROJECT_ROOT}/scripts/ensure-monitoring.sh"
}

#
# Reset Tempo state (delete and recreate with clean storage)
#
reset_tempo_state() {
    log_section "Resetting Tempo State (Fresh)"
    
    log_info "Deleting all trace generator jobs..."
    oc delete jobs -l app=trace-generator -n "$PERF_TEST_NAMESPACE" --ignore-not-found=true --wait=true
    
    log_info "Deleting query generator deployment..."
    oc delete deployment query-load-generator -n "$PERF_TEST_NAMESPACE" --ignore-not-found=true --wait=true
    
    log_info "Deleting TempoMonolithic..."
    oc delete tempomonolithic simplest -n "$PERF_TEST_NAMESPACE" --ignore-not-found=true --wait=true
    
    log_info "Deleting MinIO deployment..."
    oc delete deployment minio -n "$PERF_TEST_NAMESPACE" --ignore-not-found=true --wait=true
    
    log_info "Deleting MinIO service..."
    oc delete service minio -n "$PERF_TEST_NAMESPACE" --ignore-not-found=true --wait=true
    
    log_info "Deleting MinIO secret..."
    oc delete secret minio -n "$PERF_TEST_NAMESPACE" --ignore-not-found=true --wait=true
    
    log_info "Deleting MinIO PVC..."
    oc delete pvc minio -n "$PERF_TEST_NAMESPACE" --ignore-not-found=true --wait=true
    
    log_wait "Waiting for all resources to be fully deleted..."
    
    # Wait for all jobs pods to be fully deleted
    while oc get pods -l app=trace-generator -n "$PERF_TEST_NAMESPACE" --no-headers 2>/dev/null | grep -q .; do
        log_wait "Waiting for trace generator pods to be deleted..."
        sleep 5
    done
    
    # Wait for PVC to be fully deleted
    while oc get pvc minio -n "$PERF_TEST_NAMESPACE" &>/dev/null; do
        log_wait "Waiting for MinIO PVC to be deleted..."
        sleep 5
    done
    
    # Wait for TempoMonolithic pods to be fully deleted
    while oc get pods -l app.kubernetes.io/name=tempo -n "$PERF_TEST_NAMESPACE" --no-headers 2>/dev/null | grep -q .; do
        log_wait "Waiting for Tempo pods to be deleted..."
        sleep 5
    done
    
    # Wait for MinIO pods to be fully deleted (correct label)
    while oc get pods -l app.kubernetes.io/name=minio -n "$PERF_TEST_NAMESPACE" --no-headers 2>/dev/null | grep -q .; do
        log_wait "Waiting for MinIO pods to be deleted..."
        sleep 5
    done
    
    log_info "Tempo state reset complete. All resources deleted."
}

#
# Deploy Tempo Monolithic
#
deploy_tempo() {
    log_section "Deploying Tempo Monolithic"
    
    "${PROJECT_ROOT}/scripts/deploy-tempo-monolithic.sh"
    
    log_info "Tempo Monolithic deployed successfully."
}

#
# Read load configuration from YAML
#
read_load_config() {
    local load_name="$1"
    local field="$2"
    
    yq eval ".loads[] | select(.name == \"$load_name\") | .$field" "$CONFIG_FILE"
}

#
# Get all load names from config
#
get_all_loads() {
    yq eval '.loads[].name' "$CONFIG_FILE"
}

#
# Get service count from config
#
get_service_count() {
    yq eval '.services | length' "$CONFIG_FILE"
}

#
# Read service configuration from YAML
#
read_service_config() {
    local index="$1"
    local field="$2"
    
    yq eval ".services[$index].$field" "$CONFIG_FILE"
}

#
# Calculate weighted average spans per trace based on service configs
# Returns the weighted sum of nspans across all services
#
calculate_weighted_avg_spans() {
    local service_count
    service_count=$(get_service_count)
    
    local total_weighted_spans=0
    
    for ((i=0; i<service_count; i++)); do
        local nspans weight
        nspans=$(read_service_config "$i" "nspans")
        weight=$(read_service_config "$i" "weight")
        
        # weighted_spans = nspans * (weight / 100)
        local weighted
        weighted=$(echo "scale=2; $nspans * $weight / 100" | bc)
        total_weighted_spans=$(echo "scale=2; $total_weighted_spans + $weighted" | bc)
    done
    
    echo "$total_weighted_spans"
}

#
# Convert MB/s to TPS using estimation config
# TPS = (mb_per_sec * 1024 * 1024) / (weighted_avg_spans * bytes_per_span) * tps_multiplier
#
convert_mb_to_tps() {
    local mb_per_sec="$1"
    local tps_multiplier="${2:-1}"  # Default multiplier is 1
    
    local bytes_per_span weighted_avg_spans bytes_per_sec tps
    
    # Get estimation config
    bytes_per_span=$(yq eval '.estimatedBytesPerSpan // 800' "$CONFIG_FILE")
    
    # Calculate weighted average spans per trace
    weighted_avg_spans=$(calculate_weighted_avg_spans)
    
    # Convert MB/s to bytes/s
    bytes_per_sec=$(echo "scale=0; $mb_per_sec * 1024 * 1024" | bc)
    
    # Calculate TPS: bytes_per_sec / (weighted_avg_spans * bytes_per_span) * multiplier
    tps=$(echo "scale=0; ($bytes_per_sec / ($weighted_avg_spans * $bytes_per_span)) * $tps_multiplier" | bc)
    
    # Ensure at least 1 TPS
    if [ "$tps" -lt 1 ]; then
        tps=1
    fi
    
    echo "$tps"
}

#
# Generate containers YAML for all services
#
generate_containers_yaml() {
    local total_tps="$1"
    local runtime="$2"
    local tempo_host="$3"
    local tempo_port="$4"
    
    local service_count
    service_count=$(get_service_count)
    
    local containers_yaml=""
    
    for ((i=0; i<service_count; i++)); do
        local service_name depth nspans weight service_tps
        service_name=$(read_service_config "$i" "name")
        depth=$(read_service_config "$i" "depth")
        nspans=$(read_service_config "$i" "nspans")
        weight=$(read_service_config "$i" "weight")
        
        # Calculate TPS for this service based on weight
        # service_tps = total_tps * weight / 100
        service_tps=$(echo "$total_tps * $weight / 100" | bc)
        
        # Ensure at least 1 TPS per service
        if [ "$service_tps" -lt 1 ]; then
            service_tps=1
        fi
        
        # Generate container YAML (8 spaces indentation for containers array)
        containers_yaml+="        - name: ${service_name//[^a-z0-9-]/-}
          image: ghcr.io/honeycombio/loadgen/loadgen:latest
          args:
            - --dataset=${service_name}
            - --tps=${service_tps}
            - --depth=${depth}
            - --nspans=${nspans}
            - --runtime=${runtime}
            - --ramptime=1s
            - --tracecount=0
            - --protocol=grpc
            - --sender=otel
            - --host=${tempo_host}:${tempo_port}
            - --insecure
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
"
    done
    
    echo "$containers_yaml"
}

#
# Generate trace generator job from template
#
generate_trace_job() {
    local load_name="$1"
    local runtime="$2"
    
    local mb_per_sec tps_multiplier tps parallelism tempo_host tempo_port namespace
    mb_per_sec=$(read_load_config "$load_name" "mb_per_sec")
    tps_multiplier=$(read_load_config "$load_name" "tps_multiplier")
    # Default to 1 if not set
    tps_multiplier=${tps_multiplier:-1}
    tps=$(convert_mb_to_tps "$mb_per_sec" "$tps_multiplier")
    parallelism=$(read_load_config "$load_name" "parallelism")
    # Use OTel Collector endpoint instead of Tempo directly
    tempo_host=$(yq eval '.otelCollector.serviceName' "$CONFIG_FILE")
    tempo_port=$(yq eval '.otelCollector.port' "$CONFIG_FILE")
    namespace=$(yq eval '.namespace' "$CONFIG_FILE")
    
    # Generate containers YAML for all services
    local containers_yaml
    containers_yaml=$(generate_containers_yaml "$tps" "$runtime" "$tempo_host" "$tempo_port")
    
    # Read template and substitute variables
    # Use a temp file to handle multi-line containers replacement
    local tmp_template
    tmp_template=$(mktemp)
    
    sed -e "s/{{LOAD_NAME}}/${load_name}/g" \
        -e "s/{{NAMESPACE}}/${namespace}/g" \
        -e "s/{{PARALLELISM}}/${parallelism}/g" \
        -e "s/{{RUNTIME}}/${runtime}/g" \
        -e "s/{{TEMPO_HOST}}/${tempo_host}/g" \
        -e "s/{{TEMPO_PORT}}/${tempo_port}/g" \
        "${TEMPLATES_DIR}/trace-generator.yaml.tmpl" > "$tmp_template"
    
    # Replace {{CONTAINERS}} placeholder with actual containers YAML
    # Using awk to handle multi-line replacement
    awk -v containers="$containers_yaml" '{gsub(/{{CONTAINERS}}/, containers); print}' "$tmp_template"
    
    rm -f "$tmp_template"
}

#
# Deploy generators for a load
#
deploy_generators() {
    local load_name="$1"
    local runtime="$2"
    
    local mb_per_sec tps_multiplier total_tps parallelism
    mb_per_sec=$(read_load_config "$load_name" "mb_per_sec")
    tps_multiplier=$(read_load_config "$load_name" "tps_multiplier")
    tps_multiplier=${tps_multiplier:-1}
    parallelism=$(read_load_config "$load_name" "parallelism")
    total_tps=$(convert_mb_to_tps "$mb_per_sec" "$tps_multiplier")
    
    log_info "Deploying generators for load: $load_name"
    log_info "Target rate: ${mb_per_sec} MB/s (${total_tps} TPS × ${parallelism} replicas, multiplier: ${tps_multiplier}x)"
    
    # Show service distribution
    local service_count
    service_count=$(get_service_count)
    log_info "Services configured: $service_count"
    
    for ((i=0; i<service_count; i++)); do
        local service_name depth nspans weight service_tps
        service_name=$(read_service_config "$i" "name")
        depth=$(read_service_config "$i" "depth")
        nspans=$(read_service_config "$i" "nspans")
        weight=$(read_service_config "$i" "weight")
        service_tps=$(echo "$total_tps * $weight / 100" | bc)
        [ "$service_tps" -lt 1 ] && service_tps=1
        log_info "  - $service_name: ${service_tps} TPS, depth=$depth, spans=$nspans (${weight}%)"
    done
    
    # Delete existing trace generator job first (Jobs are immutable)
    log_info "Cleaning up any existing trace generator job..."
    oc delete job "generate-traces-${load_name}" -n "$PERF_TEST_NAMESPACE" --ignore-not-found=true --wait=true
    
    # Deploy trace generator
    log_info "Deploying multi-service trace generator..."
    generate_trace_job "$load_name" "$runtime" | oc apply -f -
    
    # Deploy query generator
    log_info "Deploying query generator..."
    oc apply -f "${PROJECT_ROOT}/generators/query-generator/manifests/deployment.yaml"
    
    # Wait for generators to start
    log_wait "Waiting for generators to start..."
    sleep 10
    
    # Check trace generator pods
    local trace_pods
    trace_pods=$(oc get pods -n "$PERF_TEST_NAMESPACE" -l "app=trace-generator,load=$load_name" --no-headers 2>/dev/null | wc -l)
    log_info "Trace generator pods: $trace_pods"
    
    # Check query generator
    local query_ready
    query_ready=$(oc get deployment query-load-generator -n "$PERF_TEST_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    log_info "Query generator replicas ready: $query_ready"
}

#
# Cleanup generators
#
cleanup_generators() {
    local load_name="$1"
    
    log_info "Cleaning up generators for load: $load_name"
    
    # Delete trace generator job
    oc delete job "generate-traces-${load_name}" -n "$PERF_TEST_NAMESPACE" --ignore-not-found=true
    
    # Scale down query generator (don't delete, just scale to 0)
    oc scale deployment query-load-generator -n "$PERF_TEST_NAMESPACE" --replicas=0 2>/dev/null || true
    
    log_info "Generators cleaned up."
}

#
# Wait for test duration
#
wait_for_duration() {
    local duration="$1"
    local load_name="$2"
    
    # Convert duration to seconds
    local seconds
    if [[ "$duration" =~ ^([0-9]+)m$ ]]; then
        seconds=$((${BASH_REMATCH[1]} * 60))
    elif [[ "$duration" =~ ^([0-9]+)h$ ]]; then
        seconds=$((${BASH_REMATCH[1]} * 3600))
    elif [[ "$duration" =~ ^([0-9]+)s$ ]]; then
        seconds=${BASH_REMATCH[1]}
    else
        seconds=$((30 * 60))  # Default 30 minutes
    fi
    
    log_section "Running Test: $load_name"
    log_info "Test duration: $duration ($seconds seconds)"
    log_info "Started at: $(date)"
    log_info "Expected completion: $(date -d "+${seconds} seconds" 2>/dev/null || date -v+${seconds}S 2>/dev/null || echo "in $duration")"
    
    # Progress display
    local elapsed=0
    local interval=60  # Update every minute
    
    while [ $elapsed -lt $seconds ]; do
        local remaining=$((seconds - elapsed))
        local remaining_min=$((remaining / 60))
        
        # Show status every minute
        if [ $((elapsed % interval)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            log_info "Progress: ${elapsed}s / ${seconds}s (${remaining_min}m remaining)"
            
            # Quick health check
            local job_status
            job_status=$(oc get job "generate-traces-${load_name}" -n "$PERF_TEST_NAMESPACE" -o jsonpath='{.status.active}' 2>/dev/null || echo "0")
            log_info "Active trace generator pods: ${job_status:-0}"
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    log_info "Test duration complete for: $load_name"
}

#
# Run a single load test
#
run_load_test() {
    local load_name="$1"
    local duration="$2"
    local test_number="$3"
    local total_tests="$4"
    
    log_section "Load Test [$test_number/$total_tests]: $load_name"
    
    local description service_count mb_per_sec tps_multiplier calculated_tps parallelism
    description=$(read_load_config "$load_name" "description")
    service_count=$(get_service_count)
    mb_per_sec=$(read_load_config "$load_name" "mb_per_sec")
    tps_multiplier=$(read_load_config "$load_name" "tps_multiplier")
    tps_multiplier=${tps_multiplier:-1}
    parallelism=$(read_load_config "$load_name" "parallelism")
    calculated_tps=$(convert_mb_to_tps "$mb_per_sec" "$tps_multiplier")
    log_info "Description: $description"
    log_info "Target rate: ${mb_per_sec} MB/s (${calculated_tps} TPS × ${parallelism} replicas across $service_count services)"
    log_info "TPS multiplier: ${tps_multiplier}x (empirical adjustment)"
    log_info "Duration: $duration"
    
    # Reset Tempo state if --fresh flag is set
    if [ "$FRESH_STATE" = true ]; then
        reset_tempo_state
        deploy_tempo
    fi
    
    # Deploy generators
    deploy_generators "$load_name" "$duration"
    
    # Wait for test duration
    wait_for_duration "$duration" "$load_name"
    
    # Collect metrics (with time-series data for the test duration)
    log_info "Collecting metrics with 1-minute granularity..."
    local raw_output="${RESULTS_DIR}/raw/${load_name}.json"
    mkdir -p "${RESULTS_DIR}/raw"
    
    # Extract duration in minutes for time-series query
    local duration_min
    duration_min=$(($(echo "$duration" | grep -oE '[0-9]+') ))
    
    "${SCRIPT_DIR}/collect-metrics.sh" "$load_name" "$raw_output" "$duration_min"
    
    # Add config info to the raw output (mb_per_sec is the primary metric now)
    # Update JSON with config
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg mb_per_sec "$mb_per_sec" --arg dur "$duration_min" \
        '. + {config: {mb_per_sec: ($mb_per_sec | tonumber), duration_minutes: ($dur | tonumber)}}' \
        "$raw_output" > "$tmp_file" && mv "$tmp_file" "$raw_output"
    
    # Cleanup generators (unless --keep-generators)
    if [ "$KEEP_GENERATORS" = false ]; then
        cleanup_generators "$load_name"
    fi
    
    log_info "Load test complete: $load_name"
}

#
# Main execution
#
main() {
    parse_args "$@"
    
    local start_time
    start_time=$(date +%s)
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       Tempo Monolithic Performance Test Framework            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Setup
    check_prerequisites
    ensure_monitoring
    
    # Only deploy Tempo initially if NOT using fresh state
    # When fresh state is enabled, deploy happens at the start of each test after cleanup
    if [ "$FRESH_STATE" = false ]; then
        deploy_tempo
    fi
    
    # Prepare results directory
    mkdir -p "${RESULTS_DIR}/raw"
    
    # Get test duration
    local duration
    if [ -n "$DURATION_OVERRIDE" ]; then
        duration="$DURATION_OVERRIDE"
    else
        duration=$(yq eval '.testDuration' "$CONFIG_FILE")
    fi
    
    # Get loads to test
    local loads_to_test=()
    if [ ${#SPECIFIC_LOADS[@]} -gt 0 ]; then
        loads_to_test=("${SPECIFIC_LOADS[@]}")
    else
        while IFS= read -r load; do
            loads_to_test+=("$load")
        done < <(get_all_loads)
    fi
    
    local total_tests=${#loads_to_test[@]}
    log_info "Will run $total_tests load test(s): ${loads_to_test[*]}"
    
    # Run each load test
    local test_number=0
    for load_name in "${loads_to_test[@]}"; do
        test_number=$((test_number + 1))
        run_load_test "$load_name" "$duration" "$test_number" "$total_tests"
    done
    
    # Generate reports
    log_section "Generating Reports"
    "${SCRIPT_DIR}/generate-report.sh" "$RESULTS_DIR"
    
    # Summary
    local end_time elapsed_min
    end_time=$(date +%s)
    elapsed_min=$(( (end_time - start_time) / 60 ))
    
    log_section "Test Suite Complete"
    log_info "Total runtime: ${elapsed_min} minutes"
    log_info "Results directory: $RESULTS_DIR"
    log_info "Reports generated in: $RESULTS_DIR"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    All Tests Complete!                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

main "$@"

