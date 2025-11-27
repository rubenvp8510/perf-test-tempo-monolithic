#!/usr/bin/env bash
set -euo pipefail

#
# generate-report.sh - Generate performance test reports
#
# Usage: ./generate-report.sh <results_dir> [output_prefix]
#
# This script aggregates raw metric files and generates:
# - CSV report for spreadsheet import
# - JSON report for programmatic processing
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF_TESTS_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$PERF_TESTS_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}✅${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠️${NC} $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }

#
# Generate CSV report
#
generate_csv() {
    local results_dir="$1"
    local output_file="$2"
    
    log_info "Generating CSV report: $output_file"
    
    # Write CSV header
    echo "load_name,tps,duration_min,p50_latency_ms,p90_latency_ms,p99_latency_ms,avg_cpu_cores,max_memory_gb,sustained_cpu_cores,peak_memory_gb,recommended_cpu,recommended_memory_gb,spans_per_sec,bytes_per_sec,query_failures_per_sec,error_rate_percent,dropped_spans_per_sec,timestamp" > "$output_file"
    
    # Process each raw JSON file
    local raw_file
    for raw_file in "$results_dir"/raw/*.json; do
        if [ ! -f "$raw_file" ]; then
            continue
        fi
        
        # Extract values from JSON
        local load_name tps duration p50 p90 p99 cpu mem sustained_cpu peak_mem rec_cpu rec_mem spans bytes failures error_rate dropped timestamp
        
        load_name=$(jq -r '.load_name // "unknown"' "$raw_file")
        tps=$(jq -r '.config.tps // 0' "$raw_file")
        duration=$(jq -r '.config.duration_minutes // 30' "$raw_file")
        
        # Latencies (convert seconds to ms)
        p50=$(jq -r '.metrics.query_latencies.p50_seconds // 0' "$raw_file")
        p90=$(jq -r '.metrics.query_latencies.p90_seconds // 0' "$raw_file")
        p99=$(jq -r '.metrics.query_latencies.p99_seconds // 0' "$raw_file")
        
        # Convert to milliseconds
        p50_ms=$(echo "scale=2; $p50 * 1000" | bc 2>/dev/null || echo "0")
        p90_ms=$(echo "scale=2; $p90 * 1000" | bc 2>/dev/null || echo "0")
        p99_ms=$(echo "scale=2; $p99 * 1000" | bc 2>/dev/null || echo "0")
        
        # Resources
        cpu=$(jq -r '.metrics.resources.avg_cpu_cores // 0' "$raw_file")
        mem=$(jq -r '.metrics.resources.max_memory_gb // 0' "$raw_file")
        sustained_cpu=$(jq -r '.metrics.resources.sustained_cpu_cores // 0' "$raw_file")
        peak_mem=$(jq -r '.metrics.resources.peak_memory_gb // 0' "$raw_file")
        
        # Resource recommendations (with 30% safety margin)
        rec_cpu=$(jq -r '.metrics.resource_recommendations.cpu_cores // 0' "$raw_file")
        rec_mem=$(jq -r '.metrics.resource_recommendations.memory_gb // 0' "$raw_file")
        
        # Throughput
        spans=$(jq -r '.metrics.throughput.spans_per_second // 0' "$raw_file")
        bytes=$(jq -r '.metrics.throughput.bytes_per_second // 0' "$raw_file")
        
        # Errors
        failures=$(jq -r '.metrics.errors.query_failures_per_second // 0' "$raw_file")
        error_rate=$(jq -r '.metrics.errors.error_rate_percent // 0' "$raw_file")
        dropped=$(jq -r '.metrics.errors.dropped_spans_per_second // 0' "$raw_file")
        
        timestamp=$(jq -r '.timestamp // ""' "$raw_file")
        
        # Write CSV row
        echo "${load_name},${tps},${duration},${p50_ms},${p90_ms},${p99_ms},${cpu},${mem},${sustained_cpu},${peak_mem},${rec_cpu},${rec_mem},${spans},${bytes},${failures},${error_rate},${dropped},${timestamp}" >> "$output_file"
    done
    
    log_info "CSV report generated with $(( $(wc -l < "$output_file") - 1 )) entries"
}

#
# Generate time-series CSV (1-minute granularity data)
#
generate_timeseries_csv() {
    local results_dir="$1"
    local output_file="$2"
    
    log_info "Generating time-series CSV: $output_file"
    
    # Write CSV header
    echo "load_name,timestamp,datetime,minute,cpu_cores,memory_gb,spans_per_sec,bytes_per_sec,p50_latency_ms,p90_latency_ms,p99_latency_ms,query_failures_per_sec,dropped_spans_per_sec" > "$output_file"
    
    local total_rows=0
    
    # Process each raw JSON file
    local raw_file
    for raw_file in "$results_dir"/raw/*.json; do
        if [ ! -f "$raw_file" ]; then
            continue
        fi
        
        local load_name
        load_name=$(jq -r '.load_name // "unknown"' "$raw_file")
        
        # Check if timeseries data exists (use spans_per_second as reference - most reliable)
        local has_timeseries
        has_timeseries=$(jq -r '.timeseries.spans_per_second | length' "$raw_file" 2>/dev/null || echo "0")
        
        if [ "$has_timeseries" = "0" ] || [ "$has_timeseries" = "null" ]; then
            log_warn "No time-series data found for load: $load_name (legacy format?)"
            continue
        fi
        
        # Extract time-series data and format as CSV rows using jq
        # Combines all metrics by timestamp
        jq -r --arg load "$load_name" '
            # Get all timeseries arrays (use spans_per_second as reference - most reliable)
            (.timeseries.cpu_cores // []) as $cpu |
            (.timeseries.memory_gb // []) as $mem |
            (.timeseries.spans_per_second // []) as $spans |
            (.timeseries.bytes_per_second // []) as $bytes |
            (.timeseries.p50_latency_seconds // []) as $p50 |
            (.timeseries.p90_latency_seconds // []) as $p90 |
            (.timeseries.p99_latency_seconds // []) as $p99 |
            (.timeseries.query_failures_per_second // []) as $failures |
            (.timeseries.dropped_spans_per_second // []) as $dropped |
            
            # Create lookup maps by timestamp
            ($cpu | map({(.timestamp | tostring): .value}) | add // {}) as $cpu_map |
            ($mem | map({(.timestamp | tostring): .value}) | add // {}) as $mem_map |
            ($spans | map({(.timestamp | tostring): .value}) | add // {}) as $spans_map |
            ($bytes | map({(.timestamp | tostring): .value}) | add // {}) as $bytes_map |
            ($p50 | map({(.timestamp | tostring): .value}) | add // {}) as $p50_map |
            ($p90 | map({(.timestamp | tostring): .value}) | add // {}) as $p90_map |
            ($p99 | map({(.timestamp | tostring): .value}) | add // {}) as $p99_map |
            ($failures | map({(.timestamp | tostring): .value}) | add // {}) as $failures_map |
            ($dropped | map({(.timestamp | tostring): .value}) | add // {}) as $dropped_map |
            
            # Get unique timestamps from spans_per_second (most reliable reference array)
            ($spans | map(.timestamp) | sort) as $timestamps |
            
            # Generate CSV rows
            $timestamps | to_entries[] |
            .key as $idx |
            .value as $ts |
            ($ts | tostring) as $ts_str |
            
            [
                $load,
                $ts,
                ($ts | todateiso8601),
                ($idx + 1),
                ($cpu_map[$ts_str] // 0),
                ($mem_map[$ts_str] // 0),
                ($spans_map[$ts_str] // 0),
                ($bytes_map[$ts_str] // 0),
                (($p50_map[$ts_str] // 0) * 1000),  # Convert to ms
                (($p90_map[$ts_str] // 0) * 1000),  # Convert to ms
                (($p99_map[$ts_str] // 0) * 1000),  # Convert to ms
                ($failures_map[$ts_str] // 0),
                ($dropped_map[$ts_str] // 0)
            ] | @csv
        ' "$raw_file" >> "$output_file" 2>/dev/null || log_warn "Failed to extract time-series for $load_name"
        
        local rows_added
        rows_added=$(jq -r '.timeseries.spans_per_second | length' "$raw_file" 2>/dev/null || echo "0")
        total_rows=$((total_rows + rows_added))
    done
    
    if [ "$total_rows" -gt 0 ]; then
        log_info "Time-series CSV generated with $total_rows data points (1-minute intervals)"
    else
        log_warn "No time-series data found in any results file"
        rm -f "$output_file"
    fi
}

#
# Generate JSON report
#
generate_json() {
    local results_dir="$1"
    local output_file="$2"
    
    log_info "Generating JSON report: $output_file"
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Get cluster info
    local cluster_name server_url
    cluster_name=$(oc config current-context 2>/dev/null || echo "unknown")
    server_url=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
    
    # Start JSON structure
    cat > "$output_file" <<EOF
{
  "report_metadata": {
    "generated_at": "${timestamp}",
    "cluster": {
      "name": "${cluster_name}",
      "server": "${server_url}"
    },
    "tool_version": "1.0.0"
  },
  "test_results": [
EOF
    
    # Process each raw JSON file
    local first=true
    local raw_file
    for raw_file in "$results_dir"/raw/*.json; do
        if [ ! -f "$raw_file" ]; then
            continue
        fi
        
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$output_file"
        fi
        
        # Read and append the raw JSON content (indented)
        jq '.' "$raw_file" | sed 's/^/    /' >> "$output_file"
    done
    
    # Close JSON structure
    cat >> "$output_file" <<EOF

  ],
  "summary": $(generate_summary "$results_dir")
}
EOF
    
    # Validate and format JSON
    if jq '.' "$output_file" > /dev/null 2>&1; then
        jq '.' "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
        log_info "JSON report generated and validated"
    else
        log_warn "JSON report may have formatting issues"
    fi
}

#
# Generate summary statistics
#
generate_summary() {
    local results_dir="$1"
    
    local total_tests=0
    local total_spans=0
    local max_p99=0
    local min_p99=999999
    
    local raw_file
    for raw_file in "$results_dir"/raw/*.json; do
        if [ ! -f "$raw_file" ]; then
            continue
        fi
        
        total_tests=$((total_tests + 1))
        
        local spans p99
        spans=$(jq -r '.metrics.throughput.spans_per_second // 0' "$raw_file")
        p99=$(jq -r '.metrics.query_latencies.p99_seconds // 0' "$raw_file")
        
        # Use awk for floating point comparison
        total_spans=$(echo "$total_spans + $spans" | bc 2>/dev/null || echo "$total_spans")
        
        if [ "$(echo "$p99 > $max_p99" | bc 2>/dev/null || echo "0")" = "1" ]; then
            max_p99=$p99
        fi
        if [ "$(echo "$p99 < $min_p99 && $p99 > 0" | bc 2>/dev/null || echo "0")" = "1" ]; then
            min_p99=$p99
        fi
    done
    
    if [ $total_tests -eq 0 ]; then
        echo '{"total_tests": 0, "message": "No test results found"}'
        return
    fi
    
    local avg_spans
    avg_spans=$(echo "scale=2; $total_spans / $total_tests" | bc 2>/dev/null || echo "0")
    
    cat <<EOF
{
    "total_tests": ${total_tests},
    "avg_spans_per_second": ${avg_spans},
    "p99_latency_range": {
      "min_seconds": ${min_p99},
      "max_seconds": ${max_p99}
    }
  }
EOF
}

#
# Print report summary to console
#
print_summary() {
    local csv_file="$1"
    local json_file="$2"
    local timeseries_file="$3"
    
    echo ""
    echo "=============================================="
    echo "Performance Test Report Summary"
    echo "=============================================="
    echo ""
    
    if [ -f "$csv_file" ]; then
        echo "Summary CSV: $csv_file"
        echo ""
        echo "Results (aggregated per load):"
        echo "------------------------------"
        # Print CSV as formatted table
        column -t -s',' "$csv_file" | head -20
        echo ""
    fi
    
    if [ -f "$timeseries_file" ]; then
        local sample_count
        sample_count=$(( $(wc -l < "$timeseries_file") - 1 ))
        echo "Time-Series CSV (1-minute intervals): $timeseries_file"
        echo "  Total data points: $sample_count"
        echo ""
    fi
    
    if [ -f "$json_file" ]; then
        echo "JSON Report: $json_file"
        echo ""
        echo "Summary:"
        jq '.summary' "$json_file" 2>/dev/null || echo "  (see JSON file for details)"
    fi
    
    echo ""
    echo "=============================================="
}

#
# Generate charts (if Python dependencies available)
#
generate_charts() {
    local results_dir="$1"
    
    # Check if Python and required modules are available
    if ! command -v python3 &> /dev/null; then
        log_warn "Python 3 not found. Skipping chart generation."
        log_warn "Install Python 3 and run: pip install -r ${PERF_TESTS_DIR}/requirements.txt"
        return 0
    fi
    
    # Check for required Python modules
    if ! python3 -c "import matplotlib, plotly, pandas" 2>/dev/null; then
        log_warn "Python chart dependencies not installed. Skipping chart generation."
        log_warn "To enable charts, run: pip install -r ${PERF_TESTS_DIR}/requirements.txt"
        return 0
    fi
    
    log_info "Generating charts..."
    if "${SCRIPT_DIR}/generate-charts.py" "$results_dir" "$timestamp"; then
        log_info "Charts generated successfully!"
    else
        log_warn "Chart generation failed, but reports are still available."
    fi
}

#
# Main
#
main() {
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <results_dir> [output_prefix] [--no-charts]"
        echo ""
        echo "Example: $0 results report"
        echo "  Creates: results/report-TIMESTAMP.csv              (summary per load)"
        echo "           results/report-TIMESTAMP-timeseries.csv   (1-minute granularity)"
        echo "           results/report-TIMESTAMP.json"
        echo "           results/charts/*.png"
        echo "           results/dashboard.html"
        echo ""
        echo "Options:"
        echo "  --no-charts    Skip chart generation"
        exit 1
    fi
    
    local results_dir="$1"
    local output_prefix="${2:-report}"
    local skip_charts=false
    local timestamp
    timestamp=$(date +"%Y%m%d-%H%M%S")
    
    # Check for --no-charts flag
    for arg in "$@"; do
        if [ "$arg" = "--no-charts" ]; then
            skip_charts=true
        fi
    done
    
    # Validate results directory
    if [ ! -d "$results_dir" ]; then
        log_error "Results directory not found: $results_dir"
        exit 1
    fi
    
    if [ ! -d "$results_dir/raw" ]; then
        log_error "Raw results directory not found: $results_dir/raw"
        exit 1
    fi
    
    # Check for jq
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed. Please install jq."
        exit 1
    fi
    
    # Check for bc
    if ! command -v bc &> /dev/null; then
        log_warn "bc not found. Some calculations may be inaccurate."
    fi
    
    local csv_file="${results_dir}/${output_prefix}-${timestamp}.csv"
    local timeseries_file="${results_dir}/${output_prefix}-${timestamp}-timeseries.csv"
    local json_file="${results_dir}/${output_prefix}-${timestamp}.json"
    
    echo "=============================================="
    echo "Generating Performance Test Reports"
    echo "=============================================="
    echo ""
    
    generate_csv "$results_dir" "$csv_file"
    generate_timeseries_csv "$results_dir" "$timeseries_file"
    generate_json "$results_dir" "$json_file"
    
    # Generate charts unless skipped
    if [ "$skip_charts" = false ]; then
        generate_charts "$results_dir"
    fi
    
    print_summary "$csv_file" "$json_file" "$timeseries_file"
    
    log_info "Report generation complete!"
}

main "$@"

