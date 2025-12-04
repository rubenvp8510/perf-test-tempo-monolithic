# Tempo Performance Test Framework Makefile
#
# Usage:
#   make perf-test              # Run full performance test suite
#   make perf-test-quick        # Run quick test (5min, low load only)
#   make perf-test-fresh        # Run tests with fresh state each time
#   make ensure-monitoring      # Setup monitoring stack
#   make deploy-tempo           # Deploy Tempo Monolithic
#   make reset-tempo            # Reset Tempo with clean state
#   make clean                  # Clean up test namespace
#   make clean-cluster          # Clean up all cluster resources
#   make clean-results          # Clean up performance test results
#   make clean-all              # Clean up everything
#

NAMESPACE := tempo-perf-test
MONITORING_NAMESPACE := tempo-monitoring
REPOSITORY := rvargasp

.PHONY: help perf-test perf-test-quick perf-test-5m perf-test-fresh ensure-monitoring deploy-tempo deploy-stack \
        gen stop-gen pods status clean clean-cluster clean-results clean-all reset-tempo build-push-gen generate-charts install-chart-deps

# Default target
help:
	@echo "Tempo Performance Test Framework"
	@echo ""
	@echo "Usage:"
	@echo "  make perf-test              Run full performance test suite (fresh state by default)"
	@echo "  make perf-test-quick        Run quick test (5min, low load only)"
	@echo "  make perf-test-5m           Run full test suite (5 minutes per test)"
	@echo "  make perf-test-1h           Run full test suite (1 hour per test)"
	@echo "  make perf-test-fresh        Run tests with fresh Tempo state each time (default)"
	@echo "  make perf-test-keep-state   Run tests keeping existing Tempo state"
	@echo "  make perf-test-load LOAD=x  Run specific load test"
	@echo "  make perf-test-duration DURATION=x  Run tests with custom duration (e.g., 1h, 2h)"
	@echo "  make generate-report        Generate reports from existing results"
	@echo "  make generate-charts        Generate charts from existing results"
	@echo "  make install-chart-deps     Install Python dependencies for charts"
	@echo "  make ensure-monitoring      Setup monitoring stack (idempotent)"
	@echo "  make deploy-tempo           Deploy Tempo Monolithic"
	@echo "  make deploy-stack           Deploy Tempo Stack"
	@echo "  make reset-tempo            Reset Tempo with clean state (delete traces)"
	@echo "  make gen                    Start load generators"
	@echo "  make stop-gen               Stop load generators"
	@echo "  make pods                   List pods in test namespace"
	@echo "  make status                 Show status of all resources"
	@echo "  make clean                  Clean up test namespace"
	@echo "  make clean-cluster          Clean up all cluster resources"
	@echo "  make clean-results          Clean up all performance test results"
	@echo "  make clean-all              Clean up everything (cluster + results)"
	@echo "  make build-push-gen         Build and push query generator image"
	@echo ""

# =============================================================================
# Performance Testing
# =============================================================================

# Run full performance test suite
perf-test: ensure-monitoring
	@echo "Running full performance test suite..."
	./perf-tests/scripts/run-perf-tests.sh

# Run quick test (5 minutes, low load only)
perf-test-quick: ensure-monitoring
	@echo "Running quick performance test..."
	./perf-tests/scripts/run-perf-tests.sh -d 5m -l low

# Run full performance test suite with fresh state for each test (now default)
perf-test-fresh: ensure-monitoring
	@echo "Running performance tests with fresh state (default behavior)..."
	./perf-tests/scripts/run-perf-tests.sh

# Run performance tests keeping existing Tempo state
perf-test-keep-state: ensure-monitoring
	@echo "Running performance tests keeping existing Tempo state..."
	./perf-tests/scripts/run-perf-tests.sh --keep-state

# Run specific load test
perf-test-load: ensure-monitoring
	@echo "Running performance test for load: $(LOAD)..."
	./perf-tests/scripts/run-perf-tests.sh -l $(LOAD)

# Run performance test with custom duration
perf-test-duration: ensure-monitoring
	@echo "Running performance test with duration: $(DURATION)..."
	./perf-tests/scripts/run-perf-tests.sh -d $(DURATION)

# Run full performance test suite for 5 minutes per test (all loads)
perf-test-5m: ensure-monitoring
	@echo "Running full performance test suite (5 minutes per test)..."
	./perf-tests/scripts/run-perf-tests.sh -d 5m

# Run full performance test suite for 1 hour per test
perf-test-1h: ensure-monitoring
	@echo "Running full performance test suite (1 hour per test)..."
	./perf-tests/scripts/run-perf-tests.sh -d 1h

# Generate report from existing results (includes charts if dependencies installed)
generate-report:
	./perf-tests/scripts/generate-report.sh ./perf-tests/results

# Generate only charts from existing results
generate-charts:
	@echo "Generating charts from test results..."
	./perf-tests/scripts/generate-charts.py ./perf-tests/results

# Install Python dependencies for chart generation
install-chart-deps:
	@echo "Installing Python dependencies for chart generation..."
	pip install -r ./perf-tests/requirements.txt

# =============================================================================
# Infrastructure Setup
# =============================================================================

# Ensure monitoring stack is ready (idempotent)
ensure-monitoring:
	@echo "Ensuring monitoring stack is ready..."
	./scripts/ensure-monitoring.sh

# Deploy Tempo Monolithic
deploy-tempo:
	@echo "Deploying Tempo Monolithic..."
	./scripts/deploy-tempo-monolithic.sh

# Deploy Tempo Stack
deploy-stack:
	@echo "Deploying Tempo Stack..."
	./scripts/deploy-tempo-stack.sh

# =============================================================================
# Load Generators
# =============================================================================

# Start load generators (trace + query)
gen:
	@echo "Starting load generators..."
	oc apply -f generators/trace-generator/job.yaml -n $(NAMESPACE)
	oc apply -f generators/query-generator/manifests/deployment.yaml -n $(NAMESPACE)

# Stop load generators
stop-gen:
	@echo "Stopping load generators..."
	oc delete job -l app=trace-generator -n $(NAMESPACE) --ignore-not-found=true
	oc scale deployment query-load-generator -n $(NAMESPACE) --replicas=0 || true

# =============================================================================
# Status & Monitoring
# =============================================================================

# List pods in test namespace
pods:
	oc get pods -n $(NAMESPACE)

# Show status of all resources
status:
	@echo "=== Pods ==="
	oc get pods -n $(NAMESPACE)
	@echo ""
	@echo "=== Jobs ==="
	oc get jobs -n $(NAMESPACE)
	@echo ""
	@echo "=== Deployments ==="
	oc get deployments -n $(NAMESPACE)
	@echo ""
	@echo "=== TempoMonolithic ==="
	oc get tempomonolithic -n $(NAMESPACE)

# Describe all pods (for debugging)
describe:
	oc describe pods -n $(NAMESPACE)

# View logs from tempo
logs-tempo:
	oc logs -n $(NAMESPACE) -l app.kubernetes.io/name=tempo --tail=100

# View logs from query generator
logs-query:
	oc logs -n $(NAMESPACE) -l app=query-load-generator --tail=100

# =============================================================================
# Cleanup
# =============================================================================

# Clean up test namespace
clean:
	@echo "Cleaning up test namespace..."
	oc delete ns $(NAMESPACE) --ignore-not-found=true

# Clean up monitoring namespace
clean-monitoring:
	@echo "Cleaning up monitoring namespace..."
	oc delete ns $(MONITORING_NAMESPACE) --ignore-not-found=true

# Clean up all cluster resources (both namespaces)
clean-cluster: clean clean-monitoring
	@echo "All cluster resources cleaned up."

# Clean up everything (cluster + results)
clean-all: clean-cluster clean-results
	@echo "All resources cleaned up."

# Clean up performance test results
clean-results:
	@echo "Cleaning up performance test results..."
	rm -f ./perf-tests/results/raw/*.json
	rm -f ./perf-tests/results/charts/*.png
	rm -f ./perf-tests/results/*.csv
	rm -f ./perf-tests/results/*.json
	rm -f ./perf-tests/results/*.html

# Reset Tempo state (delete and recreate with clean storage)
reset-tempo:
	@echo "Resetting Tempo state (deleting jobs, traces and storage)..."
	oc delete jobs -l app=trace-generator -n $(NAMESPACE) --ignore-not-found=true --wait=true
	oc delete deployment query-load-generator -n $(NAMESPACE) --ignore-not-found=true --wait=true
	oc delete tempomonolithic simplest -n $(NAMESPACE) --ignore-not-found=true --wait=true
	@echo "Deleting OpenTelemetry Collector..."
	@oc delete opentelemetrycollector otel-collector -n $(NAMESPACE) --ignore-not-found=true --wait=true || true
	@oc delete deployment otel-collector-collector -n $(NAMESPACE) --ignore-not-found=true --wait=true || true
	@oc delete deployment otel-collector -n $(NAMESPACE) --ignore-not-found=true --wait=true || true
	@oc delete serviceaccount otel-collector-sa -n $(NAMESPACE) --ignore-not-found=true --wait=true || true
	@oc delete role otel-collector-role -n $(NAMESPACE) --ignore-not-found=true --wait=true || true
	@oc delete rolebinding otel-collector-rolebinding -n $(NAMESPACE) --ignore-not-found=true --wait=true || true
	@oc delete clusterrole allow-write-traces-tenant-1 --ignore-not-found=true --wait=true || true
	@oc delete clusterrolebinding allow-write-traces-tenant-1 --ignore-not-found=true --wait=true || true
	oc delete deployment minio -n $(NAMESPACE) --ignore-not-found=true --wait=true
	oc delete service minio -n $(NAMESPACE) --ignore-not-found=true --wait=true
	oc delete secret minio -n $(NAMESPACE) --ignore-not-found=true --wait=true
	@echo "Waiting for all pods to terminate before deleting PVC..."
	@while oc get pods -l app.kubernetes.io/name=tempo -n $(NAMESPACE) --no-headers 2>/dev/null | grep -q .; do sleep 2; done
	@while oc get pods -l app.kubernetes.io/name=opentelemetry-collector -n $(NAMESPACE) --no-headers 2>/dev/null | grep -q .; do sleep 2; done
	@while oc get pods -l app.kubernetes.io/name=minio -n $(NAMESPACE) --no-headers 2>/dev/null | grep -q .; do sleep 2; done
	@echo "Deleting MinIO PVC..."
	@oc delete pvc minio -n $(NAMESPACE) --ignore-not-found=true --wait=true || true
	@echo "Waiting for MinIO PVC to be fully deleted..."
	@timeout=60; elapsed=0; \
	while oc get pvc minio -n $(NAMESPACE) &>/dev/null && [ $$elapsed -lt $$timeout ]; do \
		echo "  Waiting for PVC deletion... ($$elapsed/$$timeout seconds)"; \
		sleep 2; \
		elapsed=$$((elapsed + 2)); \
	done; \
	if oc get pvc minio -n $(NAMESPACE) &>/dev/null; then \
		echo "PVC deletion stuck, attempting to remove finalizers..."; \
		oc patch pvc minio -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true; \
		sleep 2; \
		oc delete pvc minio -n $(NAMESPACE) --ignore-not-found=true --force --grace-period=0 || true; \
	fi
	@echo "Cleaning up associated Persistent Volume (if exists)..."
	@pv_name=$$(oc get pvc minio -n $(NAMESPACE) -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo ""); \
	if [ -n "$$pv_name" ] && oc get pv $$pv_name &>/dev/null; then \
		pv_status=$$(oc get pv $$pv_name -o jsonpath='{.status.phase}' 2>/dev/null || echo ""); \
		if [ "$$pv_status" = "Released" ] || [ "$$pv_status" = "Available" ]; then \
			echo "  Deleting PV $$pv_name (status: $$pv_status)..."; \
			oc delete pv $$pv_name --ignore-not-found=true || true; \
		fi; \
	fi; \
	pvs=$$(oc get pv --no-headers 2>/dev/null | grep -E "minio|$(NAMESPACE)" | awk '{print $$1}' || true); \
	if [ -n "$$pvs" ]; then \
		for pv in $$pvs; do \
			pv_status=$$(oc get pv $$pv -o jsonpath='{.status.phase}' 2>/dev/null || echo ""); \
			if [ "$$pv_status" = "Released" ] || [ "$$pv_status" = "Available" ]; then \
				echo "  Deleting orphaned PV $$pv (status: $$pv_status)..."; \
				oc delete pv $$pv --ignore-not-found=true || true; \
			fi; \
		done; \
	fi
	@echo "Verifying cleanup is complete..."
	@if oc get pvc minio -n $(NAMESPACE) &>/dev/null; then \
		echo "  WARNING: MinIO PVC still exists"; \
		exit 1; \
	else \
		echo "  MinIO PVC deleted successfully"; \
	fi
	@echo "Redeploying Tempo..."
	./scripts/deploy-tempo-monolithic.sh

# =============================================================================
# Development
# =============================================================================

# Build and push query generator image
build-push-gen:
	@echo "Building query-load-generator image..."
	docker build -t quay.io/$(REPOSITORY)/query-load-generator:latest ./generators/query-generator
	@echo "Pushing query-load-generator image..."
	docker push quay.io/$(REPOSITORY)/query-load-generator:latest

# Run query generator locally (for development)
run-gen-local:
	cd generators/query-generator && CONFIG_FILE=config.yaml go run main.go
