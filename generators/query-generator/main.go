package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"gopkg.in/yaml.v3"
)

// Config represents the YAML configuration structure
type Config struct {
	Jaeger struct {
		QueryEndpoint    string `yaml:"queryEndpoint"`
		TimestampSeconds bool   `yaml:"timestampSeconds"`
	} `yaml:"jaeger"`
	Namespace string `yaml:"namespace"`
	Query     struct {
		Delay             string `yaml:"delay"`
		ConcurrentQueries int    `yaml:"concurrentQueries"`
	} `yaml:"query"`
	TimeBuckets []struct {
		Name     string `yaml:"name"`
		AgeStart string `yaml:"ageStart"`
		AgeEnd   string `yaml:"ageEnd"`
		Weight   int    `yaml:"weight"`
	} `yaml:"timeBuckets"`
	Queries []struct {
		Name string `yaml:"name"`
		Path string `yaml:"path"`
	} `yaml:"queries"`
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

func main() {
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

	// Parse query delay
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

	// Seed random number generator
	rand.Seed(time.Now().UnixNano())

	// Create and start query executors
	for _, q := range config.Queries {
		qs := queryExecutor{
			name:          q.Name,
			namespace:     config.Namespace,
			queryEndpoint: config.Jaeger.QueryEndpoint,
			query:         q.Path,
			delay:         queryDelay,
			tsInSeconds:   config.Jaeger.TimestampSeconds,
			timeBuckets:   timeBuckets,
			concurrency:   concurrentQueries,
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
	query         string
	tsInSeconds   bool
	delay         time.Duration
	timeBuckets   []timeBucket
	concurrency   int
}

func (queryExecutor queryExecutor) run() error {
	tokenPath := "/var/run/secrets/kubernetes.io/serviceaccount/token"
	http.DefaultTransport.(*http.Transport).TLSClientConfig = &tls.Config{InsecureSkipVerify: true}

	token, err := os.ReadFile(tokenPath)
	if err != nil {
		log.Printf("Warning: Failed to read token: %v", err)
	} else {
		log.Printf("ServiceAccount Token loaded")
	}

	client := http.Client{
		Timeout: time.Minute * 15,
	}

	reqHist := promauto.NewHistogram(prometheus.HistogramOpts{
		Namespace:   "query_load_test",
		Name:        strings.ReplaceAll(queryExecutor.namespace, "-", "_"),
		ConstLabels: prometheus.Labels{"name": queryExecutor.name},
	})

	failCounter := promauto.NewCounter(prometheus.CounterOpts{
		Namespace:   "query_failures_count",
		Name:        strings.ReplaceAll(queryExecutor.namespace, "-", "_"),
		ConstLabels: prometheus.Labels{"name": queryExecutor.name},
	})

	// Add bucket-specific metrics
	bucketCounter := promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "query_load_test",
		Subsystem: "time_bucket",
		Name:      "queries_total",
		Help:      "Total queries executed per time bucket",
	}, []string{"bucket", "query_name"})

	bucketDuration := promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "query_load_test",
		Subsystem: "time_bucket",
		Name:      "duration_seconds",
		Help:      "Query duration per time bucket",
	}, []string{"bucket", "query_name"})

	log.Printf("Starting query executor for: %s (concurrency: %d)\n", queryExecutor.name, queryExecutor.concurrency)

	// Track when this executor started for time-aware bucket selection
	testStartTime := time.Now()

	// Launch N independent tickers for concurrent execution
	for i := 0; i < queryExecutor.concurrency; i++ {
		workerID := i + 1
		// Each ticker starts with a random initial delay to spread the load
		ticker := time.NewTicker(time.Duration(rand.Int63n(int64(queryExecutor.delay))))

		go func(id int) {
			for range ticker.C {
				// Select a time bucket for this query (only from eligible buckets based on elapsed time)
				bucket := selectTimeBucket(queryExecutor.timeBuckets, testStartTime)
				if bucket == nil {
					log.Printf("[worker-%d] No eligible time buckets yet (test running for %v), skipping", id, time.Since(testStartTime))
					ticker.Reset(queryExecutor.delay)
					continue
				}

				// Calculate time range based on bucket
				now := time.Now()
				endTime := now.Add(-bucket.ageStart)
				startTime := now.Add(-bucket.ageEnd)

				// Add some randomization within the bucket
				jitter := time.Duration(rand.Int63n(int64(bucket.ageEnd - bucket.ageStart)))
				endTime = endTime.Add(-jitter)
				startTime = startTime.Add(-jitter)

				var endTimeStamp, startTimeStamp string
				if queryExecutor.tsInSeconds {
					endTimeStamp = fmt.Sprintf("%d", endTime.Unix())
					startTimeStamp = fmt.Sprintf("%d", startTime.Unix())
				} else {
					endTimeStamp = fmt.Sprintf("%d", endTime.UnixMicro())
					startTimeStamp = fmt.Sprintf("%d", startTime.UnixMicro())
				}

				// Create a new request for each query
				req, err := http.NewRequest(http.MethodGet, fmt.Sprintf("%s%s", queryExecutor.queryEndpoint, queryExecutor.query), nil)
				if err != nil {
					log.Printf("[worker-%d] error creating http request: %v", id, err)
					failCounter.Inc()
					bucketCounter.WithLabelValues(bucket.name, queryExecutor.name).Inc()
					ticker.Reset(time.Duration(rand.Int63n(int64(queryExecutor.delay))))
					continue
				}

				if token != nil {
					req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", string(token)))
				}

				q := req.URL.Query()
				q.Set("end", endTimeStamp)
				q.Set("start", startTimeStamp)
				req.URL.RawQuery = q.Encode()

				start := time.Now()
				res, err := client.Do(req)
				if err != nil {
					log.Printf("[worker-%d] error making http request: %v", id, err)
					failCounter.Inc()
					bucketCounter.WithLabelValues(bucket.name, queryExecutor.name).Inc()
					ticker.Reset(time.Duration(rand.Int63n(int64(queryExecutor.delay))))
					continue
				}

				queryDuration := time.Since(start).Seconds()
				reqHist.Observe(queryDuration)
				bucketDuration.WithLabelValues(bucket.name, queryExecutor.name).Observe(queryDuration)
				bucketCounter.WithLabelValues(bucket.name, queryExecutor.name).Inc()

				if res.StatusCode >= 300 {
					failCounter.Inc()
					log.Printf("[worker-%d] Query failed [%s]: req: %v, status: %d\n", id, bucket.name, req.URL.RawQuery, res.StatusCode)
				} else {
					log.Printf("[worker-%d] [%s] %s took %.3f seconds --> status: %d, timeRange: %s to %s\n",
						id, bucket.name, queryExecutor.name, queryDuration, res.StatusCode,
						startTime.Format("15:04:05"), endTime.Format("15:04:05"))
				}
				res.Body.Close()

				// Reset ticker with random delay
				ticker.Reset(time.Duration(rand.Int63n(int64(queryExecutor.delay))))
			}
		}(workerID)
	}

	return nil
}
