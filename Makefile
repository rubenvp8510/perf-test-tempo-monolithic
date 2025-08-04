NAMESPACE := tempo-perf-test
QUERY_FILE := ./query-load-generator/queries.txt
LOAD_GEN := tempo/04-load-generator.yaml
REPOSITORY := rvargasp
.PHONY: clean apply refresh reset-gen logs status describe

clean:
	oc delete ns $(NAMESPACE)

apply-monolithic:
	./deploy_tempo_monolithic.sh

apply-stack:
	./deploy_tempo_stack.sh

refresh:
	oc apply -f tempo

reset-gen:
	oc delete -f generator/
	oc create configmap queries --from-file=./query-load-generator/queries.txt -n $(NAMESPACE)
	oc apply -f generator/

pods:
	oc get pods -n $(NAMESPACE)

status:
	kubectl get all -n $(NAMESPACE)

describe:
	kubectl describe pods -n $(NAMESPACE)
	oc create configmap queries --from-file=$(QUERY_FILE) -o yaml --dry-run=client | kubectl apply -n $(NAMESPACE) -f -


build-push-gen:
	docker build -t quay.io/${REPOSITORY}/query-load-generator:latest ./query-load-generator
	echo "Pushing the query-load-generator image to GitHub registry..."
	echo "Make sure you are logged into GitHub Container Registry."
	docker push  quay.io/${REPOSITORY}/query-load-generator:latest