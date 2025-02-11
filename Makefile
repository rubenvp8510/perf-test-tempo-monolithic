
clean:
	oc delete ns tempo-perf-test

apply:
	oc create ns tempo-perf-test
	oc create configmap queries --from-file=./query-load-generator/queries.txt -o yaml --dry-run=client | kubectl apply -n tempo-perf-test -f -
	oc apply -f tempo

refresh:
	oc apply -f tempo
