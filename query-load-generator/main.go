package main

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	queryEndpoint := os.Getenv("JAEGER_QUERY_ENDPOINT")
	if queryEndpoint == "" {
		log.Fatalf("JAEGER_QUERY_ENDPOINT is not defined")
	}

	queryFileName := os.Getenv("QUERY_FILE")
	if queryFileName == "" {
		log.Fatalf("QUERY_FILE file is not defined")
	}

	queryDelayStr := os.Getenv("QUERY_DELAY")
	if queryDelayStr == "" {
		log.Fatalf("QUERY_DELAY is not defined")
	}
	queryLookBackStr := os.Getenv("QUERY_LOOKBACK")
	if queryLookBackStr == "" {
		log.Fatalf("QUERY_LOOKBACK is not defined")
	}
	queryLookback, err := time.ParseDuration(queryLookBackStr)
	if err != nil {
		log.Fatalf("failed to parse QUERY_LOOKBACK: %v", err)
	}

	timestampSecondsEnv := os.Getenv("TIMESTAMP_SECONDS")
	tsInSeconds := false
	if timestampSecondsEnv != "" {
		tsInSeconds, err = strconv.ParseBool(timestampSecondsEnv)
		if err != nil {
			log.Fatalf("failed to parse TIMESTAMP_SECONDS: %v", err)
		}
	}

	namespace := os.Getenv("NAMESPACE")
	if namespace == "" {
		log.Fatalf("NAMESPACE is not defined")
	}
	queryDelay, err := time.ParseDuration(queryDelayStr)
	if err != nil {
		log.Fatalf("Could not parse query duration: %v", err)
	}

	queries, err := loadFile(queryFileName)
	if err != nil {
		log.Fatalf("could not open query file: %v", err)
	}
	for _, s := range queries {
		split := strings.Split(s, "|")
		if len(split) != 2 {
			log.Fatalf("query file has incorrect format, correct is e.g.: name|/api/traces?foo=bar")
		}
		qs := queryExecutor{
			name:          split[0],
			namespace:     namespace,
			queryEndpoint: queryEndpoint,
			query:         split[1],
			delay:         queryDelay,
			lookBack:      queryLookback,
			tsInSeconds:   tsInSeconds,
		}
		if qs.run() != nil {
			log.Fatalf("Could not run query executor: %v", err)
		}
	}

	http.Handle("/metrics", promhttp.Handler())
	http.ListenAndServe(":2112", nil)
}

func loadFile(fileName string) ([]string, error) {
	queryFile, err := os.Open(fileName)
	if err != nil {
		return nil, err
	}
	reader := bufio.NewReader(queryFile)
	var queries []string
	for {
		line, err := reader.ReadString('\n')
		if err == io.EOF {
			break
		}
		if line == "" {
			continue
		}
		queries = append(queries, line[:len(line)-1])
	}
	return queries, nil
}

type queryExecutor struct {
	name          string
	namespace     string
	queryEndpoint string
	query         string
	tsInSeconds   bool
	delay         time.Duration
	lookBack      time.Duration
}

func (queryExecutor queryExecutor) run() error {
	req, err := http.NewRequest(http.MethodGet, fmt.Sprintf("%s%s", queryExecutor.queryEndpoint, queryExecutor.query), nil)
	tokenPath := "/var/run/secrets/kubernetes.io/serviceaccount/token"

	http.DefaultTransport.(*http.Transport).TLSClientConfig = &tls.Config{InsecureSkipVerify: true}

	token, err := os.ReadFile(tokenPath)
	fmt.Println("ServiceAccount Token:", string(token))

	if err != nil {
		log.Fatalf("Failed to read token: %v", err)
	}

	if err != nil {
		return err
	}
	q := req.URL.Query()
	endTime := time.Now()
	startTime := time.Now().Add(-queryExecutor.lookBack)

	var endTimeStamp, startTimeStamp string

	if queryExecutor.tsInSeconds {
		endTimeStamp = fmt.Sprintf("%d", endTime.Unix())
		startTimeStamp = fmt.Sprintf("%d", startTime.Unix())
	} else {
		endTimeStamp = fmt.Sprintf("%d", endTime.UnixMicro())
		startTimeStamp = fmt.Sprintf("%d", startTime.UnixMicro())
	}

	q.Set("end", endTimeStamp)
	q.Set("start", startTimeStamp)
	req.URL.RawQuery = q.Encode()
	//req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", token))

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

	log.Printf("Going to run: %v\n", req)
	ticker := time.NewTicker(time.Duration(rand.Int63n(int64(queryExecutor.delay))))
	go func() {
		for {
			select {
			case <-ticker.C:
				start := time.Now()
				res, err := client.Do(req)
				if err != nil {
					log.Fatalf("error making http request: %v", err)
				}
				queryDuration := time.Since(start).Seconds()
				reqHist.Observe(queryDuration)
				if res.StatusCode >= 300 {
					failCounter.Inc()
					log.Fatalf("Query failed: req: %v, res: %v", req, res)
				}
				log.Printf("%s took %f seconds --> %v\n", req.URL.RawQuery, queryDuration, res)
				res.Body.Close()

				if queryExecutor.tsInSeconds {
					endTimeStamp = fmt.Sprintf("%d", endTime.Unix())
					startTimeStamp = fmt.Sprintf("%d", startTime.Unix())
				} else {
					endTimeStamp = fmt.Sprintf("%d", endTime.UnixMicro())
					startTimeStamp = fmt.Sprintf("%d", startTime.UnixMicro())
				}

				// update times
				q.Set("end", endTimeStamp)
				q.Set("start", startTimeStamp)
				req.URL.RawQuery = q.Encode()

				// run with different delay
				ticker.Reset(time.Duration(rand.Int63n(int64(queryExecutor.delay))))
			}
		}
	}()
	return nil
}
