#!/bin/bash

set -e

if [[ $# != 2 ]]
then
  echo "Usage: $0 tanzu-network-username tanzu-network-password" >&2
  exit 1
fi
USERNAME="$1"
PASSWORD="$2"

# To run with docker-machine:
#
#  docker-machine create --virtualbox-cpu-count 4 --virtualbox-memory 16384 --virtualbox-disk-size 10000 default
#  eval "$(docker-machine env)"
#  kind create cluster --image kindest/node:v1.19.11
#  kind get kubeconfig > ~/.kube/dmkind.config
#  export KUBECONFIG=~/.kube/dmkind.config
#  K8S_PORT=$(kind get kubeconfig | grep server: | cut -d: -f4)
#  docker-machine ssh default -f -N -L $K8S_PORT:127.0.0.1:$K8S_PORT
  
kapp deploy -a kc -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/latest/download/release.yml -y
kubectl create ns tap-install
kubectl create secret docker-registry tap-registry -n tap-install --docker-server='registry.pivotal.io' --docker-username="$USERNAME" --docker-password="$PASSWORD"

cat > tap-package-repo.yaml <<EOF
apiVersion: packaging.carvel.dev/v1alpha1
kind: PackageRepository
metadata:
  name: tanzu-tap-repository
spec:
  fetch:
    imgpkgBundle:
      image: registry.pivotal.io/tanzu-application-platform/tap-packages:0.1.0
      secretRef:
        name: tap-registry
EOF
kapp deploy -a tap-package-repo -n tap-install -f ./tap-package-repo.yaml -y
tanzu package repository list -n tap-install

cat > cnr-values.yaml <<EOF
---
registry:
 server: "registry.pivotal.io"
 username: "$USERNAME"
 password: "$PASSWORD"

provider: "local"
pdb:
 enable: "true"

ingress:
 reuse_crds:
 external:
   namespace:
 internal:
   namespace:    

local_dns:
  enable: "true"
  domain: "vcap.me"
EOF

tanzu package install cloud-native-runtimes -p cnrs.tanzu.vmware.com -v 1.0.1 -n tap-install -f cnr-values.yaml --poll-timeout 10m
kapp inspect -n tap-install -a cloud-native-runtimes-ctrl -y

kapp deploy -a flux -f https://github.com/fluxcd/flux2/releases/download/v0.15.0/install.yaml -y

# Remove flux networkpolicies (known to cause problems with Traefik)
kubectl delete networkpolicy allow-egress -n flux-system
kubectl delete networkpolicy allow-scraping -n flux-system
kubectl delete networkpolicy allow-webhooks -n flux-system

cat > app-accelerator-values.yaml <<EOF
---
registry:
  server: "registry.pivotal.io"
  username: "$USERNAME"
  password: "$PASSWORD"
server:
  # Set this service_type to "NodePort" for local clusters like minikube.
  service_type: "NodePort"
  watched_namespace: "default"
  engine_invocation_url: "http://acc-engine.accelerator-system.svc.cluster.local/invocations"
engine:
  service_type: "ClusterIP"
EOF

tanzu package install app-accelerator -p accelerator.apps.tanzu.vmware.com -v 0.2.0 -n tap-install -f app-accelerator-values.yaml --poll-timeout 10m
kapp inspect -n tap-install -a app-accelerator-ctrl
kubectl get all -n accelerator-system
kubectl -n accelerator-system describe service acc-ui-server

cat > sample-accelerators-0-2.yaml <<EOF
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: new-accelerator
spec:
  git:
    url: https://github.com/sample-accelerators/new-accelerator
    ref:
      branch: main
      tag: v0.2.x
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: hello-fun
spec:
  git:
    url: https://github.com/sample-accelerators/hello-fun
    ref:
      branch: main
      tag: v0.2.x
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: hello-ytt
spec:
  git:
    url: https://github.com/sample-accelerators/hello-ytt
    ref:
      branch: main
      tag: v0.2.x
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: spring-petclinic
spec:
  git:
    ignore: ".git"
    url: https://github.com/sample-accelerators/spring-petclinic
    ref:
      branch: main
      tag: v0.2.x
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: spring-sql-jpa
spec:
  git:
    url: https://github.com/sample-accelerators/spring-sql-jpa
    ref:
      branch: main
      tag: v0.2.x
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: node-accelerator
spec:
  git:
    url: https://github.com/sample-accelerators/node-accelerator
    ref:
      branch: main
      tag: v0.2.x
EOF

kubectl apply -f sample-accelerators-0-2.yaml 
kubectl port-forward service/acc-ui-server 8877:80 -n accelerator-system &

cat > app-live-view-values.yaml <<EOF
---
registry:
  server: "registry.pivotal.io"
  username: "$USERNAME"
  password: "$PASSWORD"
EOF

tanzu package install app-live-view -p appliveview.tanzu.vmware.com -v 0.1.0 -n tap-install -f app-live-view-values.yaml --poll-timeout 10m
# kubectl describe service/application-live-view-7000 -n tap-install
# kubectl describe service/application-live-view-5112 -n tap-install
kubectl port-forward service/application-live-view-5112 5112:5112 -n tap-install &
