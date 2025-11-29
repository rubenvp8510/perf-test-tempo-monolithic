# Query Generator - Execution Plan Configuration

## Overview

The query generator now uses a **config-based execution plan** instead of code-generated plans. All query patterns are defined in the `config.yaml` file, and only time ranges are computed dynamically at runtime.

## How It Works

### 1. Execution Plan in Config

Define your query execution pattern in the `executionPlan` section of `config.yaml`:

```yaml
executionPlan:
  - queryName: "resource_service_frontend"
    bucketName: "recent"
  - queryName: "span_http_get"
    bucketName: "ingester"
  - queryName: "duration_gt_100ms"
    bucketName: "backend-1h"
  # ... more entries
```

### 2. Dynamic Time Range Calculation

- The generator cycles through the execution plan entries
- For each entry, it computes the time range dynamically based on:
  - Current time (`now`)
  - The bucket definition (ageStart, ageEnd)
  - Random jitter within the bucket range

### 3. Query Distribution

- Each query type filters the execution plan for its own entries
- Workers cycle through their matching entries (repeats when exhausted)
- This ensures the exact distribution you define in the config

## Benefits

✅ **No Code Changes Required** - Modify query patterns without rebuilding  
✅ **Full Control** - Define exact distribution and bucket usage  
✅ **Simple** - All configuration in one place  
✅ **Dynamic Time Ranges** - Time windows adapt to current time automatically  
✅ **Flexible** - Easy to create different test scenarios

## Example Scenarios

### Equal Distribution Across Buckets

```yaml
executionPlan:
  - queryName: "query1"
    bucketName: "recent"
  - queryName: "query1"
    bucketName: "ingester"
  - queryName: "query1"
    bucketName: "backend-1h"
```

### Focus on Recent Data

```yaml
executionPlan:
  - queryName: "query1"
    bucketName: "recent"
  - queryName: "query1"
    bucketName: "recent"
  - queryName: "query1"
    bucketName: "ingester"
  - queryName: "query1"
    bucketName: "backend-1h"
```

### Round-Robin Across Queries

```yaml
executionPlan:
  - queryName: "query1"
    bucketName: "recent"
  - queryName: "query2"
    bucketName: "recent"
  - queryName: "query3"
    bucketName: "recent"
  - queryName: "query1"
    bucketName: "ingester"
  - queryName: "query2"
    bucketName: "ingester"
  - queryName: "query3"
    bucketName: "ingester"
```

## Time Bucket Definitions

Time buckets define relative time ranges from the current moment:

```yaml
timeBuckets:
  - name: "recent"
    ageStart: "30s"      # End of time window (30s ago)
    ageEnd: "2m"         # Start of time window (2m ago)
    weight: 20           # Used for logging/reference only
```

At runtime, if the current time is `15:00:00`:
- A "recent" bucket query would search: `14:58:00` to `14:59:30` (plus random jitter)
- Time ranges are always calculated relative to "now"

## Migration from Old Approach

**Before:** Plan generated programmatically with round-robin + weighted selection  
**After:** Plan defined explicitly in config, time ranges computed at runtime  

### What Changed

- ❌ Removed: `planFile` config option
- ❌ Removed: `--generate-plan` CLI flag
- ❌ Removed: Plan generation code
- ✅ Added: `executionPlan` config section
- ✅ Added: Dynamic jitter calculation

### What Stayed the Same

- Time bucket definitions
- Query definitions
- QPS and concurrency settings
- Metrics and monitoring
- Runtime behavior (cycling, distribution)

## Deployment

The deployment no longer needs a separate plan ConfigMap:

```yaml
volumes:
  - name: config
    configMap:
      name: query-load-config
```

Everything is now in the main config ConfigMap.

