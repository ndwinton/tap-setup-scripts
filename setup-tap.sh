#!/bin/bash

set -e

function log() {
  echo ""
  echo ">>>"
  echo ">>> $*"
  echo ">>>"
  echo ""
}

function findOrPrompt() {
  local varName="$1"
  local prompt="$2"

  if [[ -z "${!varName}" ]]
  then
    read -p "$prompt: " $varName
  else
    echo "Value for $varName found in environment"
  fi
}

TAP_VERSION=0.2.0

cat <<EOT
WARNING: This script is a work-in-progress for TAP Beta 2.
For a working Beta 1 install check out the *beta-1-setup* tag.

This script is not yet finished. It will fail in unexpected ways.
It could damage your system. It may ruin your day. Use at your
own risk.
---------

This script will set up Tanzu Application Platform ($TAP_VERSION) on a machine
with the necessary tooling (Carvel tools, kpack and knative clients)
already installed, along with a Kubernetes cluster.

You will need an account on the Tanzu Network (aka PivNet) and an account
for a container registry, such as DockerHub or Harbor.

If set, values will be taken from TN_USERNAME and TN_PASSWORD for
the Tanzu Network and REGISTRY, REG_USERNAME and REG_PASSWORD for
the registry. If the value are not found in the environment they
will be prompted for.

EOT
findOrPrompt TN_USERNAME "Tanzu Network Username"
findOrPrompt TN_PASSWORD "Tanzu Network Password (will be echoed)"

cat <<EOT

The container registry should be something like 'myuser/tap' for DockerHub or
'harbor-repo.example.com/myuser/tap' for an internal registry.

EOT
findOrPrompt REGISTRY "Container Registry"
findOrPrompt REG_USERNAME "Registry Username"
findOrPrompt REG_PASSWORD "Registry Password (will be echoed)"

REG_HOST=${REGISTRY%%/*}
if [[ $REG_HOST != *.* ]]
then
  # Using DockerHub
  REG_HOST='index.docker.io'
fi

log "Deploying kapp-controller"
kapp deploy -a kc -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/latest/download/release.yml -y
kubectl get deployment kapp-controller -n kapp-controller  -o yaml | grep kapp-controller.carvel.dev/version:

log "Deploying secretgen-controller"
kapp deploy -a sg -f https://github.com/vmware-tanzu/carvel-secretgen-controller/releases/latest/download/release.yml -y
kubectl get deployment secretgen-controller -n secretgen-controller -o yaml | grep secretgen-controller.carvel.dev/version:

log "Deploying cert-manager"
kapp deploy -a cert-manager -f https://github.com/jetstack/cert-manager/releases/download/v1.5.3/cert-manager.yaml -y
kubectl get deployment cert-manager -n cert-manager -o yaml | grep -m 1 'app.kubernetes.io/version: v'

log "Deploying FluxCD source-controller"
(kubectl get ns flux-system 2> /dev/null) || \
  kubectl create namespace flux-system
(kubectl get clusterrolebinding default-admin 2> /dev/null) || \
kubectl create clusterrolebinding default-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=flux-system:default
kapp deploy -a flux-source-controller -n flux-system -y \
  -f https://github.com/fluxcd/source-controller/releases/download/v0.15.4/source-controller.crds.yaml \
  -f https://github.com/fluxcd/source-controller/releases/download/v0.15.4/source-controller.deployment.yaml

log "Creating tap-install namespace"
(kubectl get ns tap-install 2> /dev/null) || \
  kubectl create ns tap-install

log "Creating tap-registry imagepullsecret"
tanzu imagepullsecret delete tap-registry --namespace tap-install -y || true
tanzu imagepullsecret add tap-registry \
  --username "$TN_USERNAME" --password "$TN_PASSWORD" \
  --registry registry.tanzu.vmware.com \
  --export-to-all-namespaces --namespace tap-install

log "Adding TAP package repository"
tanzu package repository delete tanzu-tap-repository -n tap-install || true
tanzu package repository add tanzu-tap-repository \
    --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$TAP_VERSION \
    --namespace tap-install
tanzu package repository get tanzu-tap-repository --namespace tap-install
while [[ $(tanzu package available list --namespace tap-install -o json) == '\[\]' ]]
do
  echo "Waiting for packages ..."
  sleep 5
done
tanzu package available list --namespace tap-install

log "Deploying Cloud Native Runtime ..."
cat > cnr-values.yaml <<EOF
---
provider: "local"   

local_dns:
  enable: "true"
  domain: "vcap.me"
EOF

tanzu package install cloud-native-runtimes -p cnrs.tanzu.vmware.com \
  -v 1.0.2 -n tap-install -f cnr-values.yaml --poll-timeout 10m
tanzu package installed get cloud-native-runtimes -n tap-install
# For more detailed information, use the following:
#  kapp inspect -n tap-install -a cloud-native-runtimes-ctrl -y

log "Setting CNR (knative) domain to vcap.me ..."

cat > vcap-me.yaml <<EOF
apiVersion: v1
data:
  vcap.me: |
kind: ConfigMap
metadata:
  name: config-domain
  namespace: knative-serving
EOF

# TODO: Verify if next command is needed
#  kubectl apply -f vcap-me.yaml

log "Creating pull-secret for default namespace and patching default service account ..."

kubectl create secret generic pull-secret --from-literal='.dockerconfigjson={}' --type=kubernetes.io/dockerconfigjson
kubectl annotate secret pull-secret secretgen.carvel.dev/image-pull-secret=""
kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "pull-secret"}]}'

log "Deploying App Accelerator ..."
cat > app-accelerator-values.yaml <<EOF
---
server:
  # Set this service_type to "NodePort" for local clusters like minikube.
  service_type: "NodePort"
  watched_namespace: "default"
EOF

tanzu package install app-accelerator -p accelerator.apps.tanzu.vmware.com \
  -v 0.3.0 -n tap-install -f app-accelerator-values.yaml --poll-timeout 10m
tanzu package installed get app-accelerator -n tap-install
# kapp inspect -n tap-install -a app-accelerator-ctrl

cat > sample-accelerators.yaml <<EOF
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
      tag: tap-beta2
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
      tag: tap-beta2
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
      tag: tap-beta2
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
      tag: tap-beta2
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
      tag: tap-beta2
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: node-express
spec:
  git:
    url: https://github.com/sample-accelerators/node-express
    ref:
      branch: main
      tag: tap-beta2
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: weatherforecast-steeltoe
spec:
  git:
    url: https://github.com/sample-accelerators/steeltoe-weatherforecast.git
    ref:
      branch: main
      tag: tap-beta2
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: weatherforecast-csharp
spec:
  git:
    url: https://github.com/sample-accelerators/csharp-weatherforecast.git
    ref:
      branch: main
      tag: tap-beta2
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: weatherforecast-fsharp
spec:
  git:
    url: https://github.com/sample-accelerators/fsharp-weatherforecast.git
    ref:
      branch: main
      tag: tap-beta2
---
apiVersion: accelerator.apps.tanzu.vmware.com/v1alpha1
kind: Accelerator
metadata:
  name: tanzu-java-web-app
spec:
  git:
    url: https://github.com/sample-accelerators/tanzu-java-web-app.git
    ref:
      branch: main
      tag: tap-beta2
EOF

kubectl apply -f sample-accelerators.yaml 

log "Installing Convention Controller"

tanzu package install convention-controller -p controller.conventions.apps.tanzu.vmware.com \
  -v 0.4.2 -n tap-install --poll-timeout 10m
tanzu package installed get convention-controller -n tap-install
kubectl get pods -n conventions-system

log "Installing Source Controller"

tanzu package install source-controller -p controller.source.apps.tanzu.vmware.com -v 0.1.2 \
  -n tap-install --poll-timeout 10m
tanzu package installed get source-controller -n tap-install
kubectl get pods -n source-system

log "Installing Tanzu Build Service"

cat > tbs-values.yaml <<EOF
---
kp_default_repository: "$REGISTRY"
kp_default_repository_username: "$REG_USERNAME"
kp_default_repository_password: "$REG_PASSWORD"
tanzunet_username: "$TN_USERNAME"
tanzunet_password: "$TN_PASSWORD"
EOF

tanzu package install tbs -p buildservice.tanzu.vmware.com \
  -v 1.3.0 -n tap-install -f tbs-values.yaml --poll-timeout 30m
tanzu package installed get buildservice.tanzu.vmware.com -n tap-install

log "Installing Supply Chain Choreographer (Cartographer)"

tanzu package install cartographer \
  --namespace tap-install \
  --package-name cartographer.tanzu.vmware.com \
  --version 0.0.6 \
  --poll-timeout 10m

log "Creating Default Supply Chain"

cat > default-supply-chain-values.yaml <<EOF
---
registry:
  server: "$REG_HOST"
  repository: "${REGISTRY##*/}"
service_account: service-account
EOF


tanzu imagepullsecret add registry-credentials \
  --registry "$REG_HOST" \
  --username "$REG_USERNAME" \
  --password "$REG_PASSWORD" \
  --export-to-all-namespaces || true

tanzu package install default-supply-chain \
   --package-name default-supply-chain.tanzu.vmware.com \
   --version 0.2.0 \
   --namespace tap-install \
   --values-file default-supply-chain-values.yaml \
  --poll-timeout 10m

log "Installing Developer Conventions"

tanzu package install developer-conventions \
  --package-name developer-conventions.tanzu.vmware.com \
  --version 0.2.0 \
  --namespace tap-install \
  --poll-timeout 10m

echo "Installing App Live View"
cat > app-live-view-values.yaml <<EOF
---
connector_namespaces: [default]
server_namespace: app-live-view
EOF

tanzu package install app-live-view \
  -p appliveview.tanzu.vmware.com -v 0.2.0 -n tap-install \
  -f app-live-view-values.yaml --poll-timeout 10m
tanzu package installed get app-live-view -n tap-install

log "Installing Service Bindings"

tanzu package install service-bindings -p service-bindings.labs.vmware.com \
  -v 0.5.0 -n tap-install  --poll-timeout 10m
tanzu package installed get service-bindings -n tap-install
kubectl get pods -n service-bindings

log "Installing Supply Chain Security Tools - Store"

cat > scst-store-values.yaml <<EOF
db_password: "PASSWORD-0123"
EOF

tanzu package install metadata-store \
  --package-name scst-store.tanzu.vmware.com \
  --version 1.0.0-beta.0 \
  --namespace tap-install \
  --values-file scst-store-values.yaml \
   --poll-timeout 10m

log "Installing Supply Chain Security Tools - Sign"

cat > scst-sign-values.yaml <<EOF
---
warn_on_unmatched: true
EOF

tanzu package install image-policy-webhook \
  --package-name image-policy-webhook.signing.run.tanzu.vmware.com \
  --version 1.0.0-beta.0 \
  --namespace tap-install \
  --values-file scst-sign-values.yaml \
  --poll-timeout 10m

log "Creating registry-credentials service account and image pull secret"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: registry-credentials
  namespace: image-policy-system
imagePullSecrets:
- name: image-pull-secret
EOF

kubectl create secret docker-registry image-pull-secret \
  --docker-server="$REG_HOST" \
  --docker-username="$REG_USERNAME" \
  --docker-password="$REG_PASSWORD" \
  --namespace image-policy-system

log "Creating basic ClusterImagePolicy"

cat <<EOF | kubectl apply -f -
apiVersion: signing.run.tanzu.vmware.com/v1alpha1
kind: ClusterImagePolicy
metadata:
 name: image-policy
spec:
 verification:
   exclude:
     resources:
       namespaces:
       - kube-system
   keys:
   - name: cosign-key
     publicKey: |
       -----BEGIN PUBLIC KEY-----
       MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEhyQCx0E9wQWSFI9ULGwy3BuRklnt
       IqozONbbdbqz11hlRJy9c7SG+hdcFl9jE9uE/dwtuwU2MqU9T/cN0YkWww==
       -----END PUBLIC KEY-----
   images:
   - namePattern: gcr.io/projectsigstore/cosign*
     keys:
     - name: cosign-key
EOF
kubectl delete pod cosign --force --grace-period=0 2> /dev/null || true
kubectl delete pod bb --force --grace-period=0 2> /dev/null || true

kubectl run cosign --image=gcr.io/projectsigstore/cosign:v1.2.1 --restart=Never --command -- sleep 5
kubectl run bb --image=busybox --restart=Never -- sleep 5

kubectl delete pod cosign --force --grace-period=0 2> /dev/null || true
kubectl delete pod bb --force --grace-period=0 2> /dev/null || true

log "Installing Supply Chain Security Tools - Scan"

STORE_URL=$(
  kubectl -n metadata-store get service -o name | \
  grep app | \
  xargs kubectl -n metadata-store get \
    -o jsonpath='{.spec.ports[].name}{"://"}{.metadata.name}{"."}{.metadata.namespace}{".svc.cluster.local:"}{.spec.ports[].port}'
  )
STORE_CA=$(kubectl get secret app-tls-cert -n metadata-store -o json | jq -r '.data."ca.crt"' | base64 -d | sed -e 's/^/  /')
cat > scst-scan-controller-values.yaml <<EOF
---
metadataStoreUrl: $STORE_URL
metadataStoreCa: |-
$STORE_CA
metadataStoreTokenSecret: metadata-store-secret
EOF

STORE_TOKEN=$(
  kubectl get secrets -n tap-install \
    -o jsonpath="{.items[?(@.metadata.annotations['kubernetes\.io/service-account\.name']=='metadata-store-tap-install-sa')].data.token}" | base64 -d
)
cat > metadata-store-secret.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: metadata-store-secret
  namespace: scan-link-system
type: kubernetes.io/opaque
stringData:
  token: $STORE_TOKEN
EOF

kubectl create namespace scan-link-system
kubectl apply -f metadata-store-secret.yaml
tanzu package install scan-controller \
  --package-name scanning.apps.tanzu.vmware.com \
  --version 1.0.0-beta \
  --namespace tap-install \
  --values-file scst-scan-controller-values.yaml \
  --poll-timeout 10m

log "Installing Supply Chain Security Tools - Scan (Grype Scanner)"

tanzu package install grype-scanner \
  --package-name grype.scanning.apps.tanzu.vmware.com \
  --version 1.0.0-beta \
  --namespace tap-install \
  --poll-timeout 10m

# kubectl describe service/application-live-view-7000 -n tap-install
# kubectl describe service/application-live-view-5112 -n tap-install

echo ">>> Setting up port forwarding for App Accelerator (http://localhost:8877) ..."
kubectl port-forward service/acc-ui-server 8877:80 -n accelerator-system &
echo ">>> Setting up port forwarding for App Live View (http://localhost:5112) ..."
kubectl port-forward service/application-live-view-5112 5112:5112 -n tap-install &

echo ">>> Setting up Tanzu Build Service ..."

echo "$TN_PASSWORD" | docker login -u "$TN_USERNAME" --password-stdin registry.pivotal.io
echo "$REG_PASSWORD" | docker login -u "$REG_USERNAME" --password-stdin $REG_HOST

echo "(Preparing to copy images)"
imgpkg copy -b "registry.pivotal.io/build-service/bundle:1.2.2" --to-repo $REGISTRY
imgpkg pull -b $REGISTRY:1.2.2 -o ./bundle

if [[ -z "$REG_HOST" ]]
then
  # Special case handling for DockerHub
  DOCKER_REPOSITORY="${REGISTRY%%/*}"
else
  DOCKER_REPOSITORY="$REGISTRY"
fi

ytt -f ./bundle/values.yaml \
  -f ./bundle/config/ \
  -v docker_repository="$DOCKER_REPOSITORY" \
  -v docker_username="$REG_USERNAME" \
  -v docker_password="$REG_PASSWORD" | \
  kbld -f ./bundle/.imgpkg/images.yml -f- | \
  kapp deploy -a tanzu-build-service -f- -y

echo ">>> Creating TBS secret and TAP service account ..."

kp secret delete tbs-secret -n tap-install 2> /dev/null || true
kubectl wait --for=delete -n tap-install secret/tbs-secret

if [[ -z "$REG_HOST" ]]
then
  DOCKER_PASSWORD="$REG_PASSWORD" kp secret create tbs-secret -n tap-install --dockerhub $REG_USERNAME
else
  REGISTRY_PASSWORD="$REG_PASSWORD" kp secret create tbs-secret -n tap-install --registry $REG_HOST --registry-user $REG_USERNAME
fi
kubectl patch serviceaccount default -p "{\"imagePullSecrets\": [{\"name\": \"tbs-secret\"}]}" -n tap-install

cat > tap-sa.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tap-service-account
  namespace: tap-install
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: cluster-admin-cluster-role
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: cluster-admin-cluster-role-binding
subjects:
- kind: ServiceAccount
  name: tap-service-account
  namespace: tap-install
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin-cluster-role
EOF
kubectl apply -f tap-sa.yaml

echo ">>> Importing the Build Service images -- this will take a long time ..."
echo "    If it fails, you can safely run 'kp import -f descriptor.yaml' to complete the process"
# descriptor-100.0.171.yaml
cat > descriptor.yaml <<EOF
apiVersion: kp.kpack.io/v1alpha3
kind: DependencyDescriptor
defaultClusterBuilder: base
defaultClusterStack: base
lifecycle:
  image: registry.pivotal.io/tbs-dependencies/lifecycle@sha256:c923a81a1c3908122e29a30bae5886646d6ec26429bad4842c67103636041d93
clusterStores:
- name: default
  sources:
  - image: registry.pivotal.io/tanzu-go-buildpack/go@sha256:9fd3ba0f1f99f7dba25d22dc955233c7b38b7f1b55b038464968d1f1e37afd3d
  - image: registry.pivotal.io/tanzu-java-buildpack/java@sha256:822a3878d14d0f454956739025587ec179015558e021b5f52b5a596d85e41d77
  - image: registry.pivotal.io/tanzu-nodejs-buildpack/nodejs@sha256:3f69994a84bab6817cb9e689ec39968a3362a9a842f63da665dfb196bcf8da6b
  - image: registry.pivotal.io/tanzu-java-native-image-buildpack/java-native-image@sha256:acfbf3b2d2d4fab1109bb43557057be0eb9d67837f67e2eeaf9e58bac512b052
  - image: registry.pivotal.io/tanzu-dotnet-core-buildpack/dotnet-core@sha256:447361df8dc041aad6544700962fbc4e8feca9e35b0a69742ad0337ed1d33f27
  - image: registry.pivotal.io/tanzu-python-buildpack/python@sha256:3a6532ddd8e5ed475ddee72cf2f23b9b60635369677083f91d786f3dbfd9856a
  - image: registry.pivotal.io/tanzu-procfile-buildpack/procfile@sha256:fadf8498e6b112221bcadc58f2e12db39734075fd5171c288cadc3b9928ec532
  - image: registry.pivotal.io/tbs-dependencies/tanzu-buildpacks_php@sha256:cdd4cba6b595eb527126b6e9f50ab508557a957193e466a75b4fe2aa10842162
  - image: registry.pivotal.io/tbs-dependencies/tanzu-buildpacks_nginx@sha256:3dbb0e732135791614d3f79b9ee35c49bcdd673940bc4167d236e2160eb11cc4
  - image: registry.pivotal.io/tbs-dependencies/tanzu-buildpacks_httpd@sha256:4e15987d21d3d4f0cbc6be0d3b283db1d3f368eb15d0b1b59d835899c8bf946c
clusterStacks:
- name: tiny
  buildImage:
    image: registry.pivotal.io/tanzu-tiny-bionic-stack/build@sha256:f5e16eaef40630a977d42870193c0062982de37eb89f396417c27a2ae1e4e65e
  runImage:
    image: registry.pivotal.io/tanzu-tiny-bionic-stack/run@sha256:813aff25d268620701c0fff49de75124d45414d01c54ecf06ebb0e6d79a2ecf1
- name: base
  buildImage:
    image: registry.pivotal.io/tanzu-base-bionic-stack/build@sha256:efd9701be3f82b32a2528a0c11672d9f895e70a44a4e7205f35525b8baf7a6d5
  runImage:
    image: registry.pivotal.io/tanzu-base-bionic-stack/run@sha256:c41ffdb02d838d408c4b13d55092a0f200a89fe7bf0bf29bd27d0fe8d6104617
- name: full
  buildImage:
    image: registry.pivotal.io/tanzu-full-bionic-stack/build@sha256:fd33db2afcf9faafa120357c8b5233a5215a5d044ad994d5bed224d9b36e8242
  runImage:
    image: registry.pivotal.io/tanzu-full-bionic-stack/run@sha256:1bb47ce400a74248f1c3cca186b3091d887ab48329025c3fcd33dc9d4675f7f0
clusterBuilders:
- name: base
  clusterStack: base
  clusterStore: default
  order:
  - group:
    - id: tanzu-buildpacks/dotnet-core
  - group:
    - id: tanzu-buildpacks/nodejs
  - group:
    - id: tanzu-buildpacks/go
  - group:
    - id: tanzu-buildpacks/python
  - group:
    - id: tanzu-buildpacks/nginx
  - group:
    - id: tanzu-buildpacks/java-native-image
  - group:
    - id: tanzu-buildpacks/java
  - group:
    - id: paketo-buildpacks/procfile
- name: full
  clusterStack: full
  clusterStore: default
  order:
  - group:
    - id: tanzu-buildpacks/dotnet-core
  - group:
    - id: tanzu-buildpacks/nodejs
  - group:
    - id: tanzu-buildpacks/go
  - group:
    - id: tanzu-buildpacks/python
  - group:
    - id: tanzu-buildpacks/php
  - group:
    - id: tanzu-buildpacks/nginx
  - group:
    - id: tanzu-buildpacks/httpd
  - group:
    - id: tanzu-buildpacks/java-native-image
  - group:
    - id: tanzu-buildpacks/java
  - group:
    - id: paketo-buildpacks/procfile
- name: tiny
  clusterStack: tiny
  clusterStore: default
  order:
  - group:
    - id: tanzu-buildpacks/go
  - group:
    - id: tanzu-buildpacks/java-native-image
  - group:
    - id: paketo-buildpacks/procfile
EOF

kp import -f descriptor.yaml
kp clusterstack list

echo ">>> COMPLETE <<<"
