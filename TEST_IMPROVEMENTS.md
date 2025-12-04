# Tempo Performance Test Improvements

## Problem Summary

Your current tests show **higher CPU usage at lower loads**, which is counterintuitive. This happens because:

1. **Query load doesn't scale proportionally with ingestion**
   - Low: 0.7 MB/s + 25 QPS = 35.7 QPS per MB/s
   - Medium: 2.0 MB/s + 50 QPS = 25.0 QPS per MB/s
   - High: 4.0 MB/s + 75 QPS = 18.8 QPS per MB/s
   - Very-high: 7.0 MB/s + 75 QPS = **10.7 QPS per MB/s** ⚠️

2. **Each test starts with empty Tempo (FRESH_STATE=true)**
   - Cold cache effects
   - No data locality benefits
   - Proportionally more overhead at low loads

3. **Query complexity vs data volume mismatch**
   - At low load: queries scan proportionally more of the dataset
   - At high load: queries are more selective (more data = better filtering)

## Recommended Fixes

### Fix 1: Scale Query Load Proportionally

**Current `loads.yaml` (broken):**
```yaml
loads:
  - name: "low"
    mb_per_sec: 0.7
    queryQPS: 25         # 35.7 QPS/MB
    
  - name: "very-high"
    mb_per_sec: 7.0
    queryQPS: 75         # 10.7 QPS/MB ❌
```

**Fixed `loads.yaml` (proportional):**
```yaml
loads:
  - name: "low"
    mb_per_sec: 0.7
    queryQPS: 15         # ~20 QPS per MB/s
    concurrentQueries: 2
    
  - name: "medium"
    mb_per_sec: 2.0
    queryQPS: 40         # ~20 QPS per MB/s
    concurrentQueries: 3
    
  - name: "high"
    mb_per_sec: 4.0
    queryQPS: 80         # ~20 QPS per MB/s
    concurrentQueries: 5
    
  - name: "very-high"
    mb_per_sec: 7.0
    queryQPS: 140        # ~20 QPS per MB/s ✅
    concurrentQueries: 8
```

### Fix 2: Add Warm-Up Period

**Problem:** Tests start with empty Tempo, causing cold-start effects.

**Solution:** Add a warm-up period before metrics collection:

1. **Option A: Longer test with warm-up (recommended)**
   ```bash
   # Change test duration
   testDuration: "45m"  # 15min warm-up + 30min measurement
   ```
   
   Then update `collect-metrics.sh` to query only the last 30 minutes:
   ```bash
   # In run-perf-tests.sh, pass actual measurement duration
   "${SCRIPT_DIR}/collect-metrics.sh" "$load_name" "$raw_output" "30"  # Last 30min only
   ```

2. **Option B: Separate warm-up phase**
   Add to `run_load_test()` in `run-perf-tests.sh`:
   ```bash
   # After deploy_generators
   log_info "Warming up for 10 minutes..."
   sleep 600  # 10 minute warm-up
   
   log_info "Starting metrics collection..."
   # Then wait_for_duration with actual test duration
   ```

### Fix 3: Use Consistent State (Optional)

**Current:** Each test starts with fresh Tempo (`FRESH_STATE=true`)

**Alternative:** Run cumulative tests to simulate real production:
```bash
# Run tests with cumulative data
./run-perf-tests.sh --keep-state -l low -l medium -l high -l very-high
```

This way:
- Low test: fresh start (0-30min)
- Medium test: builds on low data (30-60min)
- High test: builds on medium data (60-90min)
- Very-high test: builds on high data (90-120min)

### Fix 4: Adjust Measurement Windows

**Current:** Uses 5m rate window for 30min tests

**Problem:** Might smooth out important variations at lower loads

**Solution:** Use adaptive windows based on load:
```yaml
loads:
  - name: "low"
    mb_per_sec: 0.7
    queryQPS: 15
    measurementWindow: "1m"  # Shorter window for low load
    
  - name: "very-high"
    mb_per_sec: 7.0
    queryQPS: 140
    measurementWindow: "5m"  # Longer window for high load
```

### Fix 5: Reduce Query Types for Fairer Comparison

**Current:** 61 different query types executed in round-robin

**Problem:** At low QPS (25), each query type gets executed ~0.4 times/sec
At high QPS (140), each query type gets ~2.3 times/sec

**Solution:** Either:
1. **Reduce query types** to most representative ones (10-15 queries)
2. **Weight queries** so critical queries get more traffic
3. **Increase base QPS** to ensure all queries run at meaningful rates

## Implementation Priority

### 🔴 Critical (Do First)
1. **Fix proportional scaling** - Update queryQPS in loads.yaml
2. **Add warm-up period** - 10-15 minutes before measurement

### 🟡 Important (Do Second)
3. **Review query types** - Reduce to ~20 most important queries
4. **Adjust concurrent queries** - Scale with load (already done)

### 🟢 Optional (Nice to Have)
5. **Cumulative testing** - Use --keep-state for some test runs
6. **Longer tests** - 45-60min for better statistical stability
7. **Add resource limits** - Set CPU/memory limits on Tempo to prevent overcommit

## Validation Steps

After applying fixes, verify:

1. **Proportional resource usage:**
   ```
   Resource usage should increase roughly linearly with load:
   - Low (0.7 MB/s):     ~X CPU, ~Y GB RAM
   - Medium (2.0 MB/s):  ~2.8X CPU, ~2.8Y GB RAM
   - High (4.0 MB/s):    ~5.7X CPU, ~5.7Y GB RAM
   - Very-high (7.0 MB/s): ~10X CPU, ~10Y GB RAM
   ```

2. **Consistent QPS-to-ingestion ratio:**
   ```
   All loads should have ~20 QPS per MB/s ± 10%
   ```

3. **Stable latencies after warm-up:**
   ```
   P50, P90, P99 should be stable in the measurement window
   (not decreasing over time = no more cache warm-up)
   ```

## Quick Fix Script

Run this to apply the critical fixes:

```bash
# Backup current config
cp perf-tests/config/loads.yaml perf-tests/config/loads.yaml.backup

# Apply fixes (you'll need to manually edit or use sed)
# Then run with warm-up:
./perf-tests/scripts/run-perf-tests.sh -d 45m  # Longer test with implicit warm-up
```

## Expected Results After Fixes

```
Load        Target MB/s  QPS   CPU (avg)  Memory  P99    Efficiency
low         0.7          15    ~2000m     ~2 GB   <1s    Baseline
medium      2.0          40    ~6000m     ~4 GB   <1.5s  3x baseline
high        4.0          80    ~12000m    ~6 GB   <2s    6x baseline
very-high   7.0          140   ~21000m    ~8 GB   <3s    10x baseline
```

Resources should now scale **roughly linearly** with load!


