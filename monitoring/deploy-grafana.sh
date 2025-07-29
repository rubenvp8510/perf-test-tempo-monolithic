NAMESPACE=tempo-monitoring

echo "✅ Enable user monitoring."

oc -n openshift-monitoring patch configmap cluster-monitoring-config -p '{"data":{"config.yaml":"enableUserWorkload: true"}}'

echo "Create project if not exist."
oc new-project  $NAMESPACE
oc project $NAMESPACE

echo "Create service account for monitoring."
oc create sa monitoring-sa -n $NAMESPACE
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z monitoring-sa 
TOKEN=$(oc create token monitoring-sa --duration=8760h -n $NAMESPACE)

echo "Create grafana secret and instance."
oc create secret generic credentials --from-literal=GF_SECURITY_ADMIN_PASSWORD=grafana --from-literal=GF_SECURITY_ADMIN_USER=root --from-literal=PROMETHEUS_TOKEN="$TOKEN" -n $NAMESPACE
oc apply -f manifests/grafana-instance.yaml -n $NAMESPACE

# Wait for the grafana service to exist (timeout: 60s)
echo "⏳ Waiting for Grafana service to be available..."
until oc get svc grafana-service -n $NAMESPACE &>/dev/null; do
  sleep 2
done
echo "✅ Grafana service is available."

oc create route edge grafana --service=grafana-service --insecure-policy=Redirect -n $NAMESPACE

echo "Create grafana prometheus datasource."
cat <<EOF | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: grafana-ds
  namespace: ${NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc:9091
    isDefault: true
    jsonData:
      tlsSkipVerify: true
      timeInterval: "5s"
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: "Bearer ${TOKEN}"
    editable: true
EOF

oc create -f manifests/tempo-dashboard.yaml -n $NAMESPACE
