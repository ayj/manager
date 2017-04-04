#!/bin/bash

set -ex

hub=gcr.io/jasonyoung-test0
tag=test
num_services=10
replicas=10
namespace=jason

function istio_install_yaml() {
    local managerHub=${1}
    local managerTag=${2}
    local mixerHub=${3}
    local mixerTag=${4}
    cat<<EOF
apiVersion: v1
kind: Service
metadata:
  name: istio-manager
  labels:
    istio: manager
spec:
  ports:
  - port: 8080
    name: http-discovery
  selector:
    istio: manager
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: istio-manager
spec:
  replicas: 1
  template:
    metadata:
      annotations:
        alpha.istio.io/sidecar: ignore
      labels:
        istio: manager
    spec:
      containers:
      - name: manager
        image: ${managerHub}/manager:${managerTag}
        imagePullPolicy: Always
        args: ["discovery", "-v", "2", "-m", "istio-mixer:9091"]
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 500m
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mixer-config
data:
  globalconfig.yml: |-
    subject: "namespace:ns"
    revision: "2022"
    adapters:
      - name: default
        kind: quotas
        impl: memQuota
        params:
      - name: default
        impl: stdioLogger
        params:
          logStream: 0 # STDERR
      - name: prometheus
        kind: metrics
        impl: prometheus
        params:
      - name: default
        impl: denyChecker
  serviceconfig.yml: |-
    subject: namespace:ns
    revision: "2022"
    rules:
            #- selector: service.name == “*”
            #- selector: service.name == "myservice"
    - selector: true
      aspects:
      - kind: metrics
        adapter: prometheus
        params:
          metrics:
          - descriptor_name: request_count
            # we want to increment this counter by 1 for each unique (source, target, service, method, response_code) tuple
            value: "1"
            labels:
              source: source.service | "unknown"
              target: target.service | "unknown"
              service: api.name | "unknown"
              method: api.method | "unknown"
              response_code: response.http.code | 200
          - descriptor_name:  request_latency
            value: response.latency | "0ms"
            labels:
              source: source.service | "unknown"
              target: target.service | "unknown"
              service: api.name | "unknown"
              method: api.method | "unknown"
              response_code: response.http.code | 200
      - kind: access-logs
        params:
          logName: "access_log"
          logFormat: 0 # Common Log Format
      - kind: application-logs
        params:
          logName: "mixer_log"
          logEntryDescriptorNames: ["default"]
---
# Mixer
apiVersion: v1
kind: Service
metadata:
  name: istio-mixer
  labels:
    app: mixer
spec:
  ports:
  - name: tcp
    port: 9091
  - name: prometheus
    port: 42422
  selector:
    app: mixer
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: istio-mixer
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: mixer
    spec:
      containers:
      - name: mixer
        image: ${mixerHub}/mixer:${mixerTag}
        imagePullPolicy: Always
        ports:
        - containerPort: 9091
        - containerPort: 42422
        args:
          - --globalConfigFile=/etc/opt/mixer/globalconfig.yml
          - --serviceConfigFile=/etc/opt/mixer/serviceconfig.yml
          - --logtostderr
          - -v
          - "3"
        volumeMounts:
          - mountPath: /etc/opt/mixer
            name: config
      volumes:
        - name: config
          configMap:
            name: mixer-config
---
EOF
}

function app_yaml() {
    local hub=${1}
    local tag=${2}
    local name=${3}
    local port=${4}
    local containerPort=${5}
    local replicas=${6}
    cat<<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  labels:
    app: ${name}
spec:
  ports:
  - port: ${port}
    name: http
    targetPort: ${containerPort}
  selector:
    app: ${name}
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: ${name}
spec:
  replicas: ${replicas}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
      - name: app
        image: ${hub}/app:${tag}
        imagePullPolicy: Always
        args:
          - --port
          - ${containerPort}
        ports:
        - containerPort: ${containerPort}
---
EOF
}

function create_yamls() {
    output_dir=${1}
    num=${2}
    for i in `seq 1 ${num}`; do
        name=test${i}
        filename=${name}.yaml
        port=$((80 + ${i}))
        # containerPort=$((8080 + ${i}))
	containerPort=$((80 + ${i}))
        app_yaml ${hub} ${tag} ${name} ${port} ${containerPort} ${replicas} > ${output_dir}/${filename}
    done
}

bin/build-images.sh --tag ${tag} --hub ${hub} --debug

kubectl get namespace ${namespace} &>/dev/null || kubectl create namespace ${namespace}
echo "Created namespace '${namespace}'. Delete namespace when done to clean-up all created resources."

istio_yaml=$(mktemp)
istio_install_yaml ${hub} ${tag} "gcr.io/istio-testing" "6655a67" > ${istio_yaml}
kubectl apply -n ${namespace} -f ${istio_yaml}
echo "Created yaml installation file for istio at ${istio_yaml}"

app_dir=$(mktemp -d)
create_yamls ${app_dir} ${num_services}
for filename in ${app_dir}/*.yaml; do
    kubectl apply -n ${namespace} -f <(istioctl kube-inject --verbosity 4 --hub ${hub} --tag ${tag} -f ${filename})
done
echo "Created kubernetes yaml files for ${num_services} services under ${app_dir}"

cat<<EOF
Run the following to sample envoy discovery stats across the
cluster of test deployments.

bazel run //test/benchmark:benchmark -- -namespace=jason -selector='istio!=manager,app!=mixer' |
    grep \
	-e '^cluster.\(rds\|cds\|sds\).upstream.rq_total' \
	-e '^cluster.\(rds\|cds\|sds\).upstream.rq_timeout' \
	-e '^cluster.\(rds\|cds\|sds\).upstream.rq_2xx' \
	-e '^cluster.\(rds\|cds\|sds\).upstream.rq_4xx' \
	-e '^cluster.\(rds\|cds\|sds\).upstream.rq_5xx' \
	| sort | column -t
EOF
