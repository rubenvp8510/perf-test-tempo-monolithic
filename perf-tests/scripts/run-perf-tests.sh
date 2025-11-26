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
# Generate trace generator job from template
#
generate_trace_job() {
    local load_name="$1"
    local runtime="$2"
    
    local tps parallelism depth nspans tempo_host tempo_port
    tps=$(read_load_config "$load_name" "tps")
    parallelism=$(read_load_config "$load_name" "parallelism")
    depth=$(read_load_config "$load_name" "depth")
    nspans=$(read_load_config "$load_name" "nspans")
    tempo_host=$(yq eval '.tempo.host' "$CONFIG_FILE")
    tempo_port=$(yq eval '.tempo.grpcPort' "$CONFIG_FILE")
    namespace=$(yq eval '.namespace' "$CONFIG_FILE")
    
    # Read template and substitute variables
    sed -e "s/{{LOAD_NAME}}/${load_name}/g" \
        -e "s/{{NAMESPACE}}/${namespace}/g" \
        -e "s/{{TPS}}/${tps}/g" \
        -e "s/{{PARALLELISM}}/${parallelism}/g" \
        -e "s/{{DEPTH}}/${depth}/g" \
        -e "s/{{NSPANS}}/${nspans}/g" \
        -e "s/{{RUNTIME}}/${runtime}/g" \
        -e "s/{{TEMPO_HOST}}/${tempo_host}/g" \
        -e "s/{{TEMPO_PORT}}/${tempo_port}/g" \
        "${TEMPLATES_DIR}/trace-generator.yaml.tmpl"
}

#
# Deploy generators for a load
#
deploy_generators() {
    local load_name="$1"
    local runtime="$2"
    
    log_info "Deploying generators for load: $load_name"
    
    # Deploy trace generator
    log_info "Deploying trace generator (TPS: $(read_load_config "$load_name" "tps"))..."
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
    
    local description
    description=$(read_load_config "$load_name" "description")
    log_info "Description: $description"
    log_info "TPS: $(read_load_config "$load_name" "tps")"
    log_info "Parallelism: $(read_load_config "$load_name" "parallelism")"
    log_info "Duration: $duration"
    
    # Deploy generators
    deploy_generators "$load_name" "$duration"
    
    # Wait for test duration
    wait_for_duration "$duration" "$load_name"
    
    # Collect metrics
    log_info "Collecting metrics..."
    local raw_output="${RESULTS_DIR}/raw/${load_name}.json"
    mkdir -p "${RESULTS_DIR}/raw"
    
    "${SCRIPT_DIR}/collect-metrics.sh" "$load_name" "$raw_output"
    
    # Add config info to the raw output
    local tps duration_min
    tps=$(read_load_config "$load_name" "tps")
    duration_min=$(($(echo "$duration" | grep -oE '[0-9]+') ))
    
    # Update JSON with config
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg tps "$tps" --arg dur "$duration_min" \
        '. + {config: {tps: ($tps | tonumber), duration_minutes: ($dur | tonumber)}}' \
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
    deploy_tempo
    
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

