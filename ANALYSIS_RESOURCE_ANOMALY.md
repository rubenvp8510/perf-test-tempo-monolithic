# Resource Consumption Anomaly Analysis

## The Problem

Your performance tests show **INVERTED resource usage** - lower loads consume more resources than higher loads:

```
Load        Ingestion    Query Load    Avg CPU    Memory    Result
            (MB/s)       (QPS)         (cores)    (GB)      
────────────────────────────────────────────────────────────────
low         0.7          25            9.41       3.91      ❌ HIGHEST CPU!
medium      2.0          50            6.72       4.31      ❌ Lower CPU??
high        4.0          75            8.52       3.40      ❌ Even less memory!
very-high   7.0          75            8.23       3.59      ❌ SAME QPS as high!
```

**This is completely wrong!** Resources should increase with load, not decrease.

---

## Root Cause Analysis

### 1. ⚠️ **Non-Proportional Query Scaling**

The ratio of queries-per-second to ingestion rate is INCONSISTENT:

```
Load        Ingestion    Query QPS    Ratio (QPS per MB/s)
────────────────────────────────────────────────────────────
low         0.7 MB/s     25           35.7 QPS/MB  ⚠️ TOO HIGH
medium      2.0 MB/s     50           25.0 QPS/MB  ⚠️ High
high        4.0 MB/s     75           18.8 QPS/MB  ⚠️ Lower
very-high   7.0 MB/s     75           10.7 QPS/MB  ❌ LOWEST!
```

**Why this is a problem:**
- At **low load**: You're doing 35 queries for every MB of data ingested
- At **very-high load**: You're doing only 11 queries for every MB of data ingested
- The "low" test is doing **3.3x more query work per MB** than "very-high"!

This explains why CPU is higher at low load - **you're hammering it with queries** relative to the data volume.

### 2. 📊 **Query-to-Data Volume Mismatch**

Think about what happens when you query a small vs large dataset:

**Low load (0.7 MB/s for 30 minutes):**
- Total data: ~1.26 GB over 30 minutes
- Queries hitting this data: 25 QPS × 1800 sec = **45,000 queries**
- Query density: **35,714 queries per GB**
- Many queries return MOST of the dataset (high CPU scanning)

**Very-high load (7.0 MB/s for 30 minutes):**
- Total data: ~12.6 GB over 30 minutes
- Queries hitting this data: 75 QPS × 1800 sec = **135,000 queries**
- Query density: **10,714 queries per GB** (3.3x less dense!)
- Queries are more selective, filter more data (lower CPU per query)

### 3. 🔄 **Fresh State Impact**

Each test starts with **empty Tempo** (`FRESH_STATE=true`):
- No cache
- No index warmth
- No compacted blocks
- More work per operation

This **proportionally hurts low-load tests more** because:
- Fixed startup costs are amortized over less throughput
- Cache never fully warms up with only 0.7 MB/s ingestion
- Higher loads benefit from better batching and caching

### 4. 🎯 **Concurrent Queries Overhead**

Your concurrent query settings scale too slowly:

```
Load        Concurrent    Queries/Thread    Efficiency
            Queries       
────────────────────────────────────────────────────────
low         2             12.5 QPS          Low batching
medium      3             16.7 QPS          Better
high        5             15.0 QPS          Good
very-high   8             9.4 QPS           Best batching
```

More concurrent queries = better connection pooling, batching, and amortization of overhead.

---

## The Fix: Proportional Scaling

### Current Configuration (BROKEN)

```yaml
loads:
  - name: "low"
    mb_per_sec: 0.7
    queryQPS: 25        # 35.7 QPS/MB ❌
    
  - name: "medium"
    mb_per_sec: 2.0
    queryQPS: 50        # 25.0 QPS/MB ❌
    
  - name: "high"
    mb_per_sec: 4.0
    queryQPS: 75        # 18.8 QPS/MB ❌
    
  - name: "very-high"
    mb_per_sec: 7.0
    queryQPS: 75        # 10.7 QPS/MB ❌ SAME AS HIGH!
```

### Fixed Configuration (PROPORTIONAL)

```yaml
loads:
  - name: "low"
    mb_per_sec: 0.7
    queryQPS: 15        # 21.4 QPS/MB ✅
    
  - name: "medium"
    mb_per_sec: 2.0
    queryQPS: 40        # 20.0 QPS/MB ✅
    
  - name: "high"
    mb_per_sec: 4.0
    queryQPS: 80        # 20.0 QPS/MB ✅
    
  - name: "very-high"
    mb_per_sec: 7.0
    queryQPS: 140       # 20.0 QPS/MB ✅
```

**Key changes:**
- ✅ All loads now have **~20 QPS per MB/s** (consistent ratio)
- ✅ "very-high" gets **140 QPS** instead of 75 (was same as "high"!)
- ✅ "low" gets **15 QPS** instead of 25 (was over-querying)

---

## Additional Improvements

### 1. Add Warm-Up Period

**Change test duration:**
```yaml
testDuration: "45m"  # 15min warm-up + 30min measurement
```

**Update metric collection to skip warm-up:**
- Only collect metrics from the last 30 minutes
- This excludes cold-start cache warming effects

### 2. Longer Measurement Windows for Stability

Add adaptive windows in `collect-metrics.sh`:
- Low load: 1-minute windows (faster response to changes)
- High load: 5-minute windows (smoother, more stable)

### 3. Consider Cumulative Testing (Optional)

Instead of fresh state each time, run tests cumulatively:
```bash
# Run all tests with shared state
./run-perf-tests.sh --keep-state -l low -l medium -l high -l very-high
```

This simulates more realistic production scenarios where Tempo already has data.

---

## Expected Results After Fix

With proportional scaling, you should see:

```
Load        Ingestion    Query QPS    Expected CPU    Expected Memory
            (MB/s)                    (cores)         (GB)
────────────────────────────────────────────────────────────────────────
low         0.7          15           ~2.5            ~2.5
medium      2.0          40           ~7.0            ~4.0
high        4.0          80           ~14.0           ~6.0
very-high   7.0          140          ~24.5           ~8.0
```

**Resource scaling should now be roughly linear:**
- 2.86x more load (medium vs low) → ~2.8x more CPU
- 2x more load (high vs medium) → ~2x more CPU
- 1.75x more load (very-high vs high) → ~1.75x more CPU

---

## How to Apply the Fix

### Option 1: Use the Improved Config (Recommended)

```bash
# Backup your current config
cp perf-tests/config/loads.yaml perf-tests/config/loads.yaml.backup

# Use the improved config
cp perf-tests/config/loads-improved.yaml perf-tests/config/loads.yaml

# Run tests with warm-up
./perf-tests/scripts/run-perf-tests.sh -d 45m
```

### Option 2: Quick Manual Edit

Edit `perf-tests/config/loads.yaml`:

```yaml
# Line 78: Change queryQPS from 25 to 15
queryQPS: 15  # was 25

# Line 86: Change queryQPS from 50 to 40
queryQPS: 40  # was 50

# Line 94: Change queryQPS from 75 to 80
queryQPS: 80  # was 75

# Line 102: Change queryQPS from 75 to 140 (CRITICAL!)
queryQPS: 140  # was 75 (same as high!)
```

### Option 3: Automated Patch

```bash
cd /home/rvargasp/redhat/perf-test-tempo-monolithic

# Apply fixes with sed
sed -i 's/queryQPS: 25/queryQPS: 15/' perf-tests/config/loads.yaml
sed -i '0,/queryQPS: 50/s//queryQPS: 40/' perf-tests/config/loads.yaml
sed -i '0,/queryQPS: 75/s//queryQPS: 80/' perf-tests/config/loads.yaml
sed -i '0,/queryQPS: 75/s//queryQPS: 140/' perf-tests/config/loads.yaml
```

---

## Validation Checklist

After running the improved tests, verify:

- [ ] CPU usage **increases** from low → very-high (no inversions)
- [ ] Memory usage **increases** or stays stable (no major decreases)
- [ ] QPS-to-ingestion ratio is **~20 QPS/MB ± 20%** for all loads
- [ ] P99 latency **increases** with load (expected under higher stress)
- [ ] No error rate spikes (should stay < 1%)
- [ ] Efficiency metric is **consistent** across loads (±20%)

---

## Why This Matters

### Current Tests Are Misleading

Your current results suggest:
- ❌ "Low load needs 9.4 cores, very-high needs only 8.2 cores"
- ❌ "We can handle more load with less resources!"
- ❌ "Memory decreases as we add load!"

This would lead to **incorrect resource provisioning** in production.

### Fixed Tests Will Show Reality

After the fix:
- ✅ "Resources scale linearly with load"
- ✅ "We can predict resource needs for any load level"
- ✅ "Tempo behaves as expected under increasing stress"

This enables **accurate capacity planning** and **cost optimization**.

---

## Questions?

If you still see anomalies after applying these fixes, check:

1. **Are Tempo resource limits set?** (CPU/memory limits in deployment)
2. **Is there external throttling?** (network, disk I/O limits)
3. **Query timeout settings?** (queries might be timing out at high load)
4. **Actual vs target ingestion rates?** (verify actual MB/s matches target)

Let me know if you need help investigating further!


