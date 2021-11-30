#!/bin/sh
set -o errexit

hostIp() {
  # This works on both macOS and Linux
  ifconfig -a | awk '/^(en|wl)/,/(inet |status|TX error)/ { if ($1 == "inet") { print $2; exit; } }'
}

# Create registry container unless it already exists
ROOT=$(cd $(dirname $0) && pwd)
REG_NAME='kind-registry'
REG_PORT='5000'
REGISTRY="$(hostIp):$REG_PORT"
running="$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  echo "Creating local registry at $REGISTRY: user = admin, password = admin"
  docker run \
    --detach \
    -v "$ROOT/auth:/auth" \
    -e "REGISTRY_AUTH=htpasswd" \
    -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
    -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd" \
    --name "$REG_NAME" \
    --publish "${REG_PORT}":5000 \
    registry:2
fi

# create a cluster with the local registry enabled in containerd
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${REGISTRY}"]
        endpoint = ["http://${REGISTRY}"]
    [plugins."io.containerd.grpc.v1.cri".registry.configs]
      [plugins."io.containerd.grpc.v1.cri".registry.configs."${REGISTRY}".tls]
        insecure_skip_verify = true
name: tap
nodes:
- role: control-plane
- role: worker
  extraPortMappings:
  - containerPort: 31443 
    hostPort: 443
  - containerPort: 31080 
    hostPort: 80
  - containerPort: 30053
    listenAddress: "127.0.0.1" 
    hostPort: 53
    protocol: udp
  - containerPort: 30053
    listenAddress: "127.0.0.1"
    hostPort: 53
    protocol: tcp
EOF

# Connect the registry to the cluster network
# (the network may already be connected)
docker network connect "kind" "${REG_NAME}" || true

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF


