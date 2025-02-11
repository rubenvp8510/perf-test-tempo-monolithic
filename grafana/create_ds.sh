#!/bin/bash
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z grafana-serviceaccount -n tempo-distributed-s3
sed -e 's/${TOKEN}/'$(oc serviceaccounts get-token grafana-serviceaccount -n tempo-distributed-s3)'/g' grafana_datasource.yaml.template | oc apply -f-
