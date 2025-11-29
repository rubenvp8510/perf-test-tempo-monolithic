package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/time/rate"
	"gopkg.in/yaml.v3"
)

// Global metrics - registered once at startup
var (
	// Query latency histogram with query name label
	queryLatencyHist *prometheus.HistogramVec

	// Query failures counter with query name label
	queryFailuresCounter *prometheus.CounterVec

	// Time bucket query counter
	bucketQueryCounter *prometheus.CounterVec

	// Time bucket duration histogram
	bucketDurationHist *prometheus.HistogramVec

	// Spans returned histogram with query name label
	spansReturnedHist *prometheus.HistogramVec
)

// PlanEntry represents a single entry in the execution plan from config
type PlanEntry struct {
	QueryName  string `yaml:"queryName"`
	BucketName string `yaml:"bucketName"`
}

// TempoSearchResponse represents the response from Tempo /api/search endpoint
type TempoSearchResponse struct {
	Traces []struct {
		TraceID  string `json:"traceID"`
		SpanSets []struct {
			Spans []struct {
				SpanID string `json:"spanID"`
			} `json:"spans"`
			Matched int `json:"matched"`
		} `json:"spanSets"`
		// For non-structural queries, spans may be at trace level
		SpanSet *struct {
			Spans []struct {
				SpanID string `json:"spanID"`
			} `json:"spans"`
			Matched int `json:"matched"`
		} `json:"spanSet,omitempty"`
	} `json:"traces"`
}

// Config represents the YAML configuration structure
type Config struct {
	Tempo struct {
		QueryEndpoint string `yaml:"queryEndpoint"`
	} `yaml:"tempo"`
	Namespace string `yaml:"namespace"`
	TenantID  string `yaml:"tenantId"`
	Query     struct {
		Delay             string  `yaml:"delay"`
		ConcurrentQueries int     `yaml:"concurrentQueries"`
		TargetQPS         float64 `yaml:"targetQPS"`
	} `yaml:"query"`
	TimeBuckets []struct {
		Name     string `yaml:"name"`
		AgeStart string `yaml:"ageStart"`
		AgeEnd   string `yaml:"ageEnd"`
		Weight   int    `yaml:"weight"`
	} `yaml:"timeBuckets"`
	Queries []struct {
		Name    string `yaml:"name"`
		TraceQL string `yaml:"traceql"`
	} `yaml:"queries"`
	ExecutionPlan []PlanEntry `yaml:"executionPlan"` // Execution plan defined in config
}

// timeBucket defines a time range for queries
type timeBucket struct {
	name     string        // bucket name (e.g., "ingester", "backend-1h")
	ageStart time.Duration // how far back to end the query window
	ageEnd   time.Duration // how far back to start the query window
	weight   int           // weight for random selection
}

// loadConfig loads and parses the YAML configuration file
func loadConfig(configPath string) (*Config, error) {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var config Config
	if err := yaml.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	return &config, nil
}


// convertTimeBuckets converts config time buckets to internal timeBucket struct
func convertTimeBuckets(configBuckets []struct {
	Name     string `yaml:"name"`
	AgeStart string `yaml:"ageStart"`
	AgeEnd   string `yaml:"ageEnd"`
	Weight   int    `yaml:"weight"`
}) ([]timeBucket, error) {
	buckets := make([]timeBucket, 0, len(configBuckets))

	for _, cb := range configBuckets {
		ageStart, err := time.ParseDuration(cb.AgeStart)
		if err != nil {
			return nil, fmt.Errorf("invalid ageStart duration in bucket %s: %v", cb.Name, err)
		}

		ageEnd, err := time.ParseDuration(cb.AgeEnd)
		if err != nil {
			return nil, fmt.Errorf("invalid ageEnd duration in bucket %s: %v", cb.Name, err)
		}

		buckets = append(buckets, timeBucket{
			name:     cb.Name,
			ageStart: ageStart,
			ageEnd:   ageEnd,
			weight:   cb.Weight,
		})
	}

	return buckets, nil
}

// selectTimeBucket selects a time bucket based on weighted random selection
// Only buckets where data could exist (ageEnd <= elapsed time) are considered
func selectTimeBucket(buckets []timeBucket, testStartTime time.Time) *timeBucket {
	elapsed := time.Since(testStartTime)

	// Filter to only buckets where data could exist
	var eligible []timeBucket
	for _, bucket := range buckets {
		if bucket.ageEnd <= elapsed {
			eligible = append(eligible, bucket)
		}
	}

	// If no buckets are eligible yet, return nil
	if len(eligible) == 0 {
		return nil
	}

	// Weighted selection from eligible buckets only
	totalWeight := 0
	for _, bucket := range eligible {
		totalWeight += bucket.weight
	}

	r := rand.Intn(totalWeight)
	cumulative := 0
	for i := range eligible {
		cumulative += eligible[i].weight
		if r < cumulative {
			return &eligible[i]
		}
	}
	return &eligible[0]
}

// initMetrics initializes all Prometheus metrics once at startup
func initMetrics(namespace string) {
	// Sanitize namespace for metric names
	sanitizedNs := strings.ReplaceAll(namespace, "-", "_")

	// Query latency histogram with query name label
	queryLatencyHist = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "query_load_test",
		Name:      sanitizedNs,
		Help:      "Query latency in seconds",
	}, []string{"name"})

	// Query failures counter with query name label
	queryFailuresCounter = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "query_failures_count",
		Name:      sanitizedNs,
		Help:      "Total query failures",
	}, []string{"name"})

	// Time bucket query counter
	bucketQueryCounter = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "query_load_test",
		Subsystem: "time_bucket",
		Name:      "queries_total",
		Help:      "Total queries executed per time bucket",
	}, []string{"bucket", "query_name"})

	// Time bucket duration histogram
	bucketDurationHist = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "query_load_test",
		Subsystem: "time_bucket",
		Name:      "duration_seconds",
		Help:      "Query duration per time bucket",
	}, []string{"bucket", "query_name"})

	// Spans returned histogram with query name label
	spansReturnedHist = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "query_load_test",
		Subsystem: "spans_returned",
		Name:      sanitizedNs,
		Help:      "Number of spans returned per query",
		Buckets:   []float64{0, 10, 50, 100, 250, 500, 1000, 2500, 5000},
	}, []string{"name"})

	log.Printf("Metrics initialized for namespace: %s (sanitized: %s)", namespace, sanitizedNs)
}

// formatRequest formats the full HTTP request details for logging
func formatRequest(req *http.Request) string {
	var buf bytes.Buffer
	buf.WriteString(fmt.Sprintf("Method: %s\n", req.Method))
	buf.WriteString(fmt.Sprintf("URL: %s\n", req.URL.String()))
	buf.WriteString("Headers:\n")
	for key, values := range req.Header {
		for _, value := range values {
			// Mask authorization token for security
			if key == "Authorization" {
				if len(value) > 20 {
					buf.WriteString(fmt.Sprintf("  %s: Bearer %s...\n", key, value[:20]))
				} else {
					buf.WriteString(fmt.Sprintf("  %s: %s\n", key, value))
				}
			} else {
				buf.WriteString(fmt.Sprintf("  %s: %s\n", key, value))
			}
		}
	}
	return buf.String()
}

func main() {
	flag.Parse()

	// Get config file path from environment variable (default to /config/config.yaml)
	configPath := os.Getenv("CONFIG_FILE")
	if configPath == "" {
		configPath = "/config/config.yaml"
	}

	log.Printf("Loading configuration from: %s", configPath)

	// Load and parse configuration
	config, err := loadConfig(configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Initialize metrics ONCE with the configured namespace
	initMetrics(config.Namespace)

	// Parse query delay (kept for backward compatibility, but not used if targetQPS is set)
	queryDelay, err := time.ParseDuration(config.Query.Delay)
	if err != nil {
		log.Fatalf("Could not parse query delay: %v", err)
	}

	// Validate concurrent queries
	concurrentQueries := config.Query.ConcurrentQueries
	if concurrentQueries < 1 {
		log.Fatalf("CONCURRENT_QUERIES must be >= 1, got: %d", concurrentQueries)
	}
	log.Printf("Concurrent queries per executor: %d", concurrentQueries)

	// Validate and calculate QPS
	targetQPS := config.Query.TargetQPS
	if targetQPS <= 0 {
		log.Fatalf("targetQPS must be > 0, got: %f", targetQPS)
	}
	log.Printf("Target total QPS: %.2f", targetQPS)

	// Convert time buckets
	timeBuckets, err := convertTimeBuckets(config.TimeBuckets)
	if err != nil {
		log.Fatalf("Failed to parse time buckets: %v", err)
	}
	log.Printf("Using time buckets: %+v", timeBuckets)

	// Validate queries
	if len(config.Queries) == 0 {
		log.Fatalf("No queries defined in configuration")
	}
	log.Printf("Loaded %d queries from configuration", len(config.Queries))

	// Calculate per-query QPS: total QPS divided by number of query types
	perQueryQPS := targetQPS / float64(len(config.Queries))
	log.Printf("Per-query QPS: %.4f (distributed across %d concurrent workers)", perQueryQPS, concurrentQueries)

	// Validate execution plan from config
	if len(config.ExecutionPlan) == 0 {
		log.Fatalf("No executionPlan defined in configuration. Please define an execution plan in config.yaml")
	}
	
	log.Printf("Loaded execution plan with %d entries from config", len(config.ExecutionPlan))
	
	// Validate plan: count entries per query and check for undefined queries
	queryDist := make(map[string]int)
	queryMap := make(map[string]bool)
	for _, q := range config.Queries {
		queryMap[q.Name] = true
	}
	
	for _, entry := range config.ExecutionPlan {
		if !queryMap[entry.QueryName] {
			log.Fatalf("Execution plan references undefined query: %s", entry.QueryName)
		}
		queryDist[entry.QueryName]++
	}
	
	log.Printf("Plan distribution across queries:")
	for queryName, count := range queryDist {
		log.Printf("  %s: %d entries (will cycle/repeat as needed)", queryName, count)
	}

	// Create and start query executors
	for _, q := range config.Queries {
		qs := queryExecutor{
			name:          q.Name,
			namespace:     config.Namespace,
			queryEndpoint: config.Tempo.QueryEndpoint,
			traceQL:       q.TraceQL,
			delay:         queryDelay,
			timeBuckets:   timeBuckets,
			concurrency:   concurrentQueries,
			tenantID:      config.TenantID,
			targetQPS:     perQueryQPS,
			executionPlan: config.ExecutionPlan,
		}
		if err := qs.run(); err != nil {
			log.Fatalf("Could not run query executor: %v", err)
		}
	}

	http.Handle("/metrics", promhttp.Handler())
	http.ListenAndServe(":2112", nil)
}

type queryExecutor struct {
	name          string
	namespace     string
	queryEndpoint string
	traceQL       string
	delay         time.Duration
	timeBuckets   []timeBucket
	concurrency   int
	tenantID      string
	targetQPS     float64
	executionPlan []PlanEntry // Execution plan from config
}

// planIndices stores atomic counters for each query name to cycle through plan entries
var planIndices = make(map[string]*int64)
var planIndicesMutex sync.Mutex

// getPlanIndex returns the atomic counter for a given query name, creating it if needed
func getPlanIndex(queryName string) *int64 {
	planIndicesMutex.Lock()
	defer planIndicesMutex.Unlock()
	
	if idx, exists := planIndices[queryName]; exists {
		return idx
	}
	
	idx := new(int64)
	planIndices[queryName] = idx
	return idx
}

func (queryExecutor queryExecutor) run() error {
	tokenPath := "/var/run/secrets/kubernetes.io/serviceaccount/token"

	token, err := os.ReadFile(tokenPath)
	if err != nil {
		log.Printf("Warning: Failed to read token: %v", err)
	} else {
		log.Printf("ServiceAccount Token loaded")
	}

	// Create custom transport with TLS config that allows self-signed certificates
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}

	client := http.Client{
		Transport: transport,
		Timeout:   time.Minute * 15,
	}

	// Use global metrics with this executor's query name as label
	queryName := queryExecutor.name

	log.Printf("Starting query executor for: %s (concurrency: %d, target QPS: %.4f)\n", queryExecutor.name, queryExecutor.concurrency, queryExecutor.targetQPS)

	// Track when this executor started for time-aware bucket selection
	testStartTime := time.Now()

	// Create a shared rate limiter for all workers of this query type
	// The limiter ensures total QPS for this query type equals targetQPS
	limiter := rate.NewLimiter(rate.Limit(queryExecutor.targetQPS), 1)
	ctx := context.Background()

	// Launch N independent workers for concurrent execution
	for i := 0; i < queryExecutor.concurrency; i++ {
		workerID := i + 1
		// Each worker starts with a small random initial delay to spread the load
		initialDelay := time.Duration(rand.Int63n(int64(time.Second)))

		go func(id int) {
			// Initial delay to spread workers
			time.Sleep(initialDelay)

			for {
				// Wait for rate limiter permission (blocks until allowed)
				if err := limiter.Wait(ctx); err != nil {
					log.Printf("[worker-%d] Rate limiter error: %v", id, err)
					return
				}

				// Determine bucket name and time range using execution plan from config
				bucketName := "immediate"
				var startTime, endTime time.Time
				var startTimeStamp, endTimeStamp string
				var bucket *timeBucket

				// Filter plan entries for this query name
				var matchingEntries []PlanEntry
				for _, entry := range queryExecutor.executionPlan {
					if entry.QueryName == queryExecutor.name {
						matchingEntries = append(matchingEntries, entry)
					}
				}

				if len(matchingEntries) > 0 {
					// Get or create index counter for this query
					planIdx := getPlanIndex(queryExecutor.name)
					idx := atomic.AddInt64(planIdx, 1) - 1
					entryIdx := int(idx) % len(matchingEntries) // Cycle through matching entries - repeats when exhausted
					entry := matchingEntries[entryIdx]
					
					// Log when we've cycled through all entries once
					if idx > 0 && idx % int64(len(matchingEntries)) == 0 {
						log.Printf("[worker-%d] Query '%s': Cycled through all %d plan entries, repeating from start (cycle: %d)", 
							id, queryExecutor.name, len(matchingEntries), idx / int64(len(matchingEntries)))
					}

					bucketName = entry.BucketName
					if bucketName != "immediate" {
						// Find the bucket by name
						for i := range queryExecutor.timeBuckets {
							if queryExecutor.timeBuckets[i].name == bucketName {
								bucket = &queryExecutor.timeBuckets[i]
								break
							}
						}

						if bucket != nil {
							// Check if bucket is eligible based on elapsed time
							elapsed := time.Since(testStartTime)
							if bucket.ageEnd <= elapsed {
								// Calculate time range dynamically with random jitter within bucket
								now := time.Now()
								bucketRange := bucket.ageEnd - bucket.ageStart
								jitter := time.Duration(0)
								if bucketRange > 0 {
									jitter = time.Duration(rand.Int63n(int64(bucketRange)))
								}
								endTime = now.Add(-bucket.ageStart).Add(-jitter)
								startTime = now.Add(-bucket.ageEnd).Add(-jitter)
								endTimeStamp = fmt.Sprintf("%d", endTime.Unix())
								startTimeStamp = fmt.Sprintf("%d", startTime.Unix())
							} else {
								// Bucket not eligible yet, use immediate
								bucket = nil
								bucketName = "immediate"
							}
						} else {
							// Bucket not found, use immediate
							bucketName = "immediate"
							log.Printf("[worker-%d] Warning: Bucket '%s' not found in timeBuckets config, using immediate", id, bucketName)
						}
					}
				} else {
					// No matching entries in plan for this query - this shouldn't happen if config is valid
					log.Printf("[worker-%d] Warning: No plan entries for query '%s', using immediate bucket", id, queryExecutor.name)
				}

				// Create a new request for Tempo TraceQL search via gateway
				// Gateway uses Observatorium API pattern: /api/traces/v1/{tenant}/api/search
				req, err := http.NewRequest(http.MethodGet, fmt.Sprintf("%s/api/traces/v1/%s/tempo/api/search", queryExecutor.queryEndpoint, queryExecutor.tenantID), nil)
				if err != nil {
					log.Printf("[worker-%d] error creating http request: %v", id, err)
					queryFailuresCounter.WithLabelValues(queryName).Inc()
					bucketQueryCounter.WithLabelValues(bucketName, queryName).Inc()
					continue
				}

				if token != nil {
					req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", string(token)))
				}

				// Add tenant ID header for multitenancy
				if queryExecutor.tenantID != "" {
					req.Header.Set("X-Scope-OrgID", queryExecutor.tenantID)
				}

				queryParams := req.URL.Query()
				queryParams.Set("q", queryExecutor.traceQL)
				// Only add time range parameters if bucket is available
				if bucket != nil {
					queryParams.Set("start", startTimeStamp)
					queryParams.Set("end", endTimeStamp)
				}
				queryParams.Set("limit", "1000")
				req.URL.RawQuery = queryParams.Encode()

				start := time.Now()
				res, err := client.Do(req)
				if err != nil {
					log.Printf("[worker-%d] error making http request: %v", id, err)
					log.Printf("[worker-%d] Full request details:\n%s", id, formatRequest(req))
					queryFailuresCounter.WithLabelValues(queryName).Inc()
					bucketQueryCounter.WithLabelValues(bucketName, queryName).Inc()
					continue
				}

				queryDuration := time.Since(start).Seconds()
				queryLatencyHist.WithLabelValues(queryName).Observe(queryDuration)
				bucketDurationHist.WithLabelValues(bucketName, queryName).Observe(queryDuration)
				bucketQueryCounter.WithLabelValues(bucketName, queryName).Inc()

				if res.StatusCode >= 300 {
					queryFailuresCounter.WithLabelValues(queryName).Inc()

					// Read response body before closing
					body, readErr := io.ReadAll(res.Body)
					res.Body.Close()

					// Log full request details
					log.Printf("[worker-%d] Query failed [%s]: status: %d", id, bucketName, res.StatusCode)
					log.Printf("[worker-%d] Full request details:\n%s", id, formatRequest(req))

					// Log response body
					if readErr != nil {
						log.Printf("[worker-%d] Failed to read response body: %v", id, readErr)
					} else {
						log.Printf("[worker-%d] Response body:\n%s", id, string(body))
					}
				} else {
					// Read and parse response to count spans
					body, err := io.ReadAll(res.Body)
					res.Body.Close()

					var spansCount int
					if err != nil {
						log.Printf("[worker-%d] error reading response body: %v", id, err)
					} else {
						var searchResp TempoSearchResponse
						if err := json.Unmarshal(body, &searchResp); err != nil {
							log.Printf("[worker-%d] error parsing response JSON: %v", id, err)
						} else {
							// Count total spans across all traces (Tempo format)
							for _, trace := range searchResp.Traces {
								// Check SpanSets (for structural queries)
								for _, spanSet := range trace.SpanSets {
									spansCount += len(spanSet.Spans)
								}
								// Check SpanSet (for non-structural queries)
								if trace.SpanSet != nil {
									spansCount += len(trace.SpanSet.Spans)
								}
							}
						}
					}

					// Always record spans returned metric (0 if parsing failed, actual count otherwise)
					spansReturnedHist.WithLabelValues(queryName).Observe(float64(spansCount))

					// Format log message with or without time range
					if bucket != nil {
						log.Printf("[worker-%d] [%s] %s took %.3f seconds --> status: %d, spans: %d, timeRange: %s to %s\n",
							id, bucketName, queryExecutor.name, queryDuration, res.StatusCode, spansCount,
							startTime.Format("15:04:05"), endTime.Format("15:04:05"))
					} else {
						log.Printf("[worker-%d] [%s] %s took %.3f seconds --> status: %d, spans: %d (immediate data, no time range)\n",
							id, bucketName, queryExecutor.name, queryDuration, res.StatusCode, spansCount)
					}
				}
				// Rate limiter will control the next iteration
			}
		}(workerID)
	}

	return nil
}
