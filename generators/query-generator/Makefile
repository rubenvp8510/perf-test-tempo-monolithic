
IMG ?= ghcr.io/rubenvp8510/perf-test-tempo-opensearch/query-load-generator
VERSION ?= 5

all: image-build image-push

image-build:
	docker build -f Dockerfile -t ${IMG}:${VERSION} .

image-push:
	docker push ${IMG}:${VERSION}

run:
	CONFIG_FILE=config.yaml go run main.go
