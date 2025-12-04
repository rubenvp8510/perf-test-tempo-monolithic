# Quick Start: Fix Resource Consumption Anomaly

## TL;DR - The Problem

Your tests show **lower loads using MORE resources** than higher loads because:
- Low load: 35.7 queries per MB/s ingested
- Very-high load: 10.7 queries per MB/s ingested (same QPS as "high" despite 75% more ingestion!)

This makes "low" tests work 3.3x harder per MB than "very-high" tests.

## TL;DR - The Fix

Make query load scale proportionally with ingestion:
- Low: 15 QPS (was 25)
- Medium: 40 QPS (was 50)
- High: 80 QPS (was 75)
- Very-high: 140 QPS (was 75) ← **Critical: was same as high!**

---

## Option 1: Interactive Fix (Recommended)

```bash
cd /home/rvargasp/redhat/perf-test-tempo-monolithic
./fix-query-scaling.sh
```

This will:
1. Show you a comparison of current vs improved config
2. Apply the fix
3. Verify it worked
4. Show expected results

---

## Option 2: Manual Quick Fix

Edit `perf-tests/config/loads.yaml`:

```yaml
# Line ~78 - Low load
queryQPS: 15  # Change from 25

# Line ~86 - Medium load
queryQPS: 40  # Change from 50

# Line ~94 - High load
queryQPS: 80  # Change from 75

# Line ~102 - Very-high load (CRITICAL!)
queryQPS: 140  # Change from 75 (was same as high!)
```

---

## Option 3: Use Pre-built Improved Config

```bash
cd /home/rvargasp/redhat/perf-test-tempo-monolithic

# Backup current config
cp perf-tests/config/loads.yaml perf-tests/config/loads.yaml.backup

# Use improved config
cp perf-tests/config/loads-improved.yaml perf-tests/config/loads.yaml
```

---

## Run New Tests

```bash
cd /home/rvargasp/redhat/perf-test-tempo-monolithic

# Run with default 45-minute duration (includes 15min warm-up)
./perf-tests/scripts/run-perf-tests.sh

# Or run specific loads
./perf-tests/scripts/run-perf-tests.sh -l high -l very-high

# Or run shorter tests for validation
./perf-tests/scripts/run-perf-tests.sh -d 30m -l low -l very-high
```

---

## Verify Results

After running the improved tests, you should see:

### ✅ Resources Scale Linearly
```
Load        Ingestion    CPU      Memory
low         0.7 MB/s     ~2.5     ~2.5 GB
medium      2.0 MB/s     ~7.0     ~4.0 GB
high        4.0 MB/s     ~14.0    ~6.0 GB
very-high   7.0 MB/s     ~24.5    ~8.0 GB
```

### ✅ Consistent QPS-to-Ingestion Ratio
```
All loads: ~20 QPS per MB/s (±20%)
```

### ✅ No Inversions
- CPU should increase: low < medium < high < very-high
- Memory should increase or stay stable
- P99 latency should increase (expected under load)

---

## What Changed in loads-improved.yaml

1. **Proportional query scaling:**
   - All loads now have ~20 QPS per MB/s
   - No more over-querying at low load

2. **Test duration increased to 45 minutes:**
   - Includes 15-minute warm-up
   - Metrics collected from last 30 minutes only

3. **Query generator delay:**
   - Changed from 5s to 15m (warm-up period)

4. **Added measurementWindow field:**
   - Low load: 1m (more responsive)
   - High loads: 5m (more stable)

---

## Detailed Documentation

- **Full analysis:** [ANALYSIS_RESOURCE_ANOMALY.md](ANALYSIS_RESOURCE_ANOMALY.md)
- **Improvements guide:** [TEST_IMPROVEMENTS.md](TEST_IMPROVEMENTS.md)
- **Improved config:** [perf-tests/config/loads-improved.yaml](perf-tests/config/loads-improved.yaml)

---

## Troubleshooting

### Still seeing anomalies?

1. **Check actual vs target ingestion rates:**
   ```bash
   # During test, check Prometheus for actual throughput
   oc port-forward -n openshift-monitoring svc/prometheus-k8s 9090:9090
   # Then query: sum(rate(tempo_distributor_bytes_received_total[5m]))
   ```

2. **Check for resource limits:**
   ```bash
   oc get tempomonolithic simplest -n tempo-perf-test -o yaml | grep -A 5 resources
   ```

3. **Check for throttling:**
   ```bash
   # Look for dropped spans
   oc logs -n tempo-perf-test -l app.kubernetes.io/name=tempo | grep -i drop
   ```

4. **Increase test duration:**
   ```bash
   # Run longer tests for more stable metrics
   ./perf-tests/scripts/run-perf-tests.sh -d 60m
   ```

---

## Questions?

See detailed analysis in:
- `ANALYSIS_RESOURCE_ANOMALY.md` - Why this happened
- `TEST_IMPROVEMENTS.md` - Complete improvement guide


