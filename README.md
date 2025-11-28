# Tempo Performance Testing Framework

A comprehensive performance testing framework for **Tempo Monolithic** on OpenShift with **multitenancy support**. This project provides automated tools for deploying Tempo, running load tests with varying TPS configurations, collecting metrics, and generating reports.

## Architecture

The framework uses **OpenTelemetry Collector** (managed by OpenTelemetry Operator) as an authentication and tenant header proxy:

- **Trace Generators** → **OTel Collector** (no auth) → **Tempo** (with OpenShift auth + tenant headers)
- **Query Generator** → **Tempo** (direct, with OpenShift auth + tenant headers)

The OTel Collector handles:
- Adding `Authorization: Bearer <token>` header for OpenShift gateway authentication
- Adding `X-Scope-OrgID: <tenant-id>` header for Tempo multitenancy isolation

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Quick Start](#quick-start)
- [Usage](#usage)
  - [Running Performance Tests](#running-performance-tests)
  - [Customizing Load Configurations](#customizing-load-configurations)
  - [Generating Reports](#generating-reports)
- [Makefile Targets](#makefile-targets)
- [Configuration](#configuration)
- [Reports](#reports)

## Features

- **Automated Performance Testing**: Run comprehensive tests with configurable TPS loads
- **Idempotent Setup**: All setup scripts are safe to run multiple times
- **Metrics Collection**: Automatically collects latencies, resource usage, throughput, and errors
- **Report Generation**: Outputs both CSV (for spreadsheets) and JSON (for programmatic use)
- **Chart Generation**: Creates static PNG charts and interactive HTML dashboards
- **Flexible Configuration**: YAML-based load configurations with easy customization
- **Monitoring Integration**: Automatic Grafana and Prometheus setup with dashboards

## Prerequisites

- **OpenShift Cluster** with admin access
- **Tempo Operator** installed (from OperatorHub)
- **Grafana Operator** installed (from OperatorHub)
- **OpenTelemetry Operator** installed (from OperatorHub) - **Required for multitenancy**
- **CLI Tools**: `oc`, `jq`, `yq`, `bc`
- **Docker** (for building custom images)
- **Python 3.8+** (optional, for chart generation)
  - Install chart dependencies: `make install-chart-deps`

## Project Structure

```
perf-test-tempo-monolithic/
├── README.md
├── Makefile                          # All make targets
│
├── deploy/                           # Deployment configurations
│   ├── tempo-monolithic/
│   │   ├── base/                     # Base Tempo configuration
│   │   └── overlays/                 # Resource overlays (small/medium/large)
│   ├── otel-collector/               # OpenTelemetry Collector for multitenancy
│   │   ├── collector.yaml            # OpenTelemetryCollector CR
│   │   └── rbac.yaml                 # ServiceAccount and RBAC
│   ├── tempo-stack/
│   └── storage/
│       └── minio.yaml                # MinIO for S3 storage
│
├── scripts/                          # Setup scripts
│   ├── deploy-tempo-monolithic.sh
│   ├── deploy-tempo-stack.sh
│   └── ensure-monitoring.sh          # Idempotent monitoring setup
│
├── generators/                       # Load generation tools
│   ├── trace-generator/
│   │   └── job.yaml
│   └── query-generator/
│       ├── Dockerfile
│       ├── main.go
│       └── manifests/
│           └── deployment.yaml
│
├── monitoring/
│   └── manifests/
│       ├── grafana-instance.yaml
│       └── tempo-dashboard.yaml
│
├── perf-tests/                       # Performance testing framework
│   ├── config/
│   │   └── loads.yaml                # Load configurations
│   ├── templates/
│   │   └── trace-generator.yaml.tmpl
│   ├── scripts/
│   │   ├── run-perf-tests.sh         # Main orchestrator
│   │   ├── collect-metrics.sh        # Prometheus metrics collector
│   │   └── generate-report.sh        # Report generator
│   └── results/                      # Test results output
│
└── docs/
```

## Quick Start

1. **Install Prerequisites**

   Ensure Tempo Operator and Grafana Operator are installed from OperatorHub.

2. **Run Performance Tests**

   ```bash
   # Run quick test (5 minutes, low load)
   make perf-test-quick

   # Run full test suite (all loads, 30 minutes each)
   make perf-test
   ```

3. **View Results**

   Results are saved in `perf-tests/results/`:
   - `report-TIMESTAMP.csv` - For spreadsheet import
   - `report-TIMESTAMP.json` - For programmatic processing
   - `charts/*.png` - Static charts (if Python deps installed)
   - `dashboard.html` - Interactive dashboard (if Python deps installed)

## Usage

### Running Performance Tests

```bash
# Full test suite (all loads defined in loads.yaml)
make perf-test

# Quick test (5 minutes, low load only)
make perf-test-quick

# Specific load only
make perf-test-load LOAD=medium

# Custom duration
./perf-tests/scripts/run-perf-tests.sh -d 15m

# Multiple specific loads
./perf-tests/scripts/run-perf-tests.sh -l low -l medium -d 20m

# Skip monitoring setup (if already configured)
./perf-tests/scripts/run-perf-tests.sh -s -d 10m
```

### Customizing Load Configurations

Edit `perf-tests/config/loads.yaml`:

```yaml
testDuration: "30m"

loads:
  - name: "low"
    description: "Low load - baseline test"
    tps: 50
    parallelism: 1
    depth: 10
    nspans: 50

  - name: "medium"
    description: "Medium load - typical production"
    tps: 150
    parallelism: 3
    depth: 10
    nspans: 50

  - name: "high"
    description: "High load - stress test"
    tps: 300
    parallelism: 3
    depth: 10
    nspans: 50
```

### Generating Reports

Reports are automatically generated after tests complete. To regenerate:

```bash
make generate-report
```

### Generating Charts

Charts are automatically generated with reports if Python dependencies are installed. To generate charts separately:

```bash
# Install dependencies (one time)
make install-chart-deps

# Generate charts from existing results
make generate-charts
```

This creates:
- **Static PNG charts** in `perf-tests/results/charts/` - for inclusion in documents
- **Interactive HTML dashboard** at `perf-tests/results/dashboard.html` - for browser viewing
- **Summary table** at `perf-tests/results/summary.html` - quick overview of all results

#### Available Charts

| Chart | Description |
|-------|-------------|
| `latency_comparison.png` | P50, P90, P99 query latencies across load levels |
| `resource_usage.png` | CPU and memory consumption per load |
| `throughput_analysis.png` | Expected vs actual spans/sec with efficiency % |
| `error_metrics.png` | Error rates and dropped spans per load |
| `dashboard.html` | Interactive dashboard with all charts |

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make help` | Show all available targets |
| `make perf-test` | Run full performance test suite |
| `make perf-test-quick` | Run quick test (5min, low load) |
| `make perf-test-load LOAD=x` | Run specific load test |
| `make generate-report` | Generate reports from existing results |
| `make generate-charts` | Generate charts from existing results |
| `make install-chart-deps` | Install Python dependencies for charts |
| `make ensure-monitoring` | Setup monitoring (idempotent) |
| `make deploy-tempo` | Deploy Tempo Monolithic |
| `make gen` | Start load generators |
| `make stop-gen` | Stop load generators |
| `make pods` | List pods in test namespace |
| `make status` | Show all resource status |
| `make clean` | Clean up test namespace |
| `make build-push-gen` | Build and push query generator image |

## Configuration

### Multitenancy Configuration

The framework supports multitenancy with configurable tenant IDs. By default, it uses `tenant-1`. To configure tenants:

1. Edit `perf-tests/config/loads.yaml`:
   ```yaml
   tenants:
     - id: "tenant-1"
       description: "Default tenant for performance testing"
   
   otelCollector:
     serviceName: "otel-collector-collector"
     port: 4317
   ```

2. The tenant ID is automatically used by:
   - OpenTelemetry Collector (for trace ingestion)
   - Query Generator (for query requests)

3. To add more tenants in the future, deploy additional OTel Collector instances with different tenant IDs.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MONITORING_NAMESPACE` | `tempo-monitoring` | Namespace for Grafana/monitoring |
| `PERF_TEST_NAMESPACE` | `tempo-perf-test` | Namespace for tests |
| `TIMEOUT` | `300` | Timeout for readiness checks (seconds) |

### Load Configuration Options

| Field | Description |
|-------|-------------|
| `name` | Unique identifier for the load |
| `description` | Human-readable description |
| `tps` | Traces per second to generate |
| `parallelism` | Number of parallel generator pods |
| `depth` | Trace tree depth |
| `nspans` | Spans per trace |

## Reports

### CSV Report Columns

| Column | Description |
|--------|-------------|
| `load_name` | Name of the load configuration |
| `tps` | Configured traces per second |
| `duration_min` | Test duration in minutes |
| `p50_latency_ms` | 50th percentile query latency |
| `p90_latency_ms` | 90th percentile query latency |
| `p99_latency_ms` | 99th percentile query latency |
| `avg_cpu_cores` | Average CPU usage (cores) |
| `max_memory_gb` | Maximum memory usage (GB) |
| `spans_per_sec` | Actual spans ingested per second |
| `error_rate_percent` | Query error rate |

### JSON Report Structure

```json
{
  "report_metadata": {
    "generated_at": "2024-01-15T10:30:00Z",
    "cluster": { "name": "...", "server": "..." }
  },
  "test_results": [
    {
      "load_name": "low",
      "metrics": {
        "query_latencies": { "p50_seconds": 0.1, "p90_seconds": 0.3, "p99_seconds": 0.5 },
        "resources": { "avg_cpu_cores": 0.5, "max_memory_gb": 2.1 },
        "throughput": { "spans_per_second": 2500 },
        "errors": { "error_rate_percent": 0.01 }
      }
    }
  ],
  "summary": { "total_tests": 4, "avg_spans_per_second": 5000 }
}
```

## Troubleshooting

### Check Pod Status
```bash
make status
make describe
```

### View Logs
```bash
make logs-tempo
make logs-query
```

### Clean Up and Restart
```bash
make clean
make perf-test
```

## References

- [Honeycomb LoadGen](https://github.com/honeycombio/loadgen) - Trace generator tool
- [Tempo Operator](https://github.com/grafana/tempo-operator) - Tempo Kubernetes Operator
