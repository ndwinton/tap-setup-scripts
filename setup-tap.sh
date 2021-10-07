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

find packageVersion() {
  tanzu package available list $1 -n tap-install -o json | jq -r '.[0].version'
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
while [[ -n $(tanzu package repository get tanzu-tap-repository -n tap-install -o json 2> /dev/null) ]]
do
  sleep 5
done
tanzu package repository add tanzu-tap-repository \
    --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$TAP_VERSION \
    --namespace tap-install
tanzu package repository get tanzu-tap-repository --namespace tap-install
while [[ $(tanzu package available list --namespace tap-install -o json) == '[]' ]]
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

CNR_VERSION=$(packageVersion cnrs.tanzu.vmware.com)
tanzu package install cloud-native-runtimes -p cnrs.tanzu.vmware.com \
  -v $CNR_VERSION -n tap-install -f cnr-values.yaml --poll-timeout 10m
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

kubectl delete secret pull-secret 2> /dev/null || true
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

AA_VERSION=$(packageVersion accelerator.apps.tanzu.vmware.com)
tanzu package install app-accelerator -p accelerator.apps.tanzu.vmware.com \
  -v $AA_VERSION -n tap-install -f app-accelerator-values.yaml --poll-timeout 10m
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

# TODO: Confirm if needed
# kubectl apply -f sample-accelerators.yaml 

log "Installing Convention Controller"

CC_VERSION=$(packageVersion controller.conventions.apps.tanzu.vmware.com)
tanzu package install convention-controller -p controller.conventions.apps.tanzu.vmware.com \
  -v $CC_VERSION -n tap-install --poll-timeout 10m
tanzu package installed get convention-controller -n tap-install
kubectl get pods -n conventions-system

log "Installing Source Controller"

SC_VERSION=$(controller.source.apps.tanzu.vmware.com)
tanzu package install source-controller -p controller.source.apps.tanzu.vmware.com \
  -v $SC_VERSION -n tap-install --poll-timeout 10m
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

BS_VERSION=$(packageVersion buildservice.tanzu.vmware.com)
tanzu package install tbs -p buildservice.tanzu.vmware.com \
  -v $BS_VERSION -n tap-install -f tbs-values.yaml --poll-timeout 30m
tanzu package installed get tbs -n tap-install

log "Installing Supply Chain Choreographer (Cartographer)"

SCC_VERSION=$(packageVersion cartographer.tanzu.vmware.com)
tanzu package install cartographer \
  --namespace tap-install \
  --package-name cartographer.tanzu.vmware.com \
  --version $SCC_VERSION \
  --poll-timeout 10m

log "Creating Default Supply Chain"

cat > default-supply-chain-values.yaml <<EOF
---
registry:
  server: "$REG_HOST"
  repository: "${REGISTRY##*/}"
service_account: service-account
EOF

tanzu imagepullsecret delete registry-credentials -y || true
tanzu imagepullsecret add registry-credentials \
  --registry "$REG_HOST" \
  --username "$REG_USERNAME" \
  --password "$REG_PASSWORD" \
  --export-to-all-namespaces || true

DSC_VERSION=$(packageVersion default-supply-chain.tanzu.vmware.com)
tanzu package install default-supply-chain \
   --package-name default-supply-chain.tanzu.vmware.com \
   --version $DSC_VERSION \
   --namespace tap-install \
   --values-file default-supply-chain-values.yaml \
  --poll-timeout 10m

log "Installing Developer Conventions"

DC_VERSION=$(packageVersion developer-conventions.tanzu.vmware.com)
tanzu package install developer-conventions \
  --package-name developer-conventions.tanzu.vmware.com \
  --version $DC_VERSION \
  --namespace tap-install \
  --poll-timeout 10m

echo "Installing App Live View"

cat > app-live-view-values.yaml <<EOF
---
connector_namespaces: [default]
server_namespace: app-live-view
EOF

(kubectl get ns app-live-view 2> /dev/null) || \
  kubectl create ns app-live-view

ALV_VERSION=$(packageVersion appliveview.tanzu.vmware.com)
tanzu package install app-live-view \
  -p appliveview.tanzu.vmware.com -v $ALV_VERSION -n tap-install \
  -f app-live-view-values.yaml --poll-timeout 10m
tanzu package installed get app-live-view -n tap-install

log "Installing Service Bindings"

SB_VERSION=$(packageVersion service-bindings.labs.vmware.com)
tanzu package install service-bindings -p service-bindings.labs.vmware.com \
  -v $SB_VERSION -n tap-install --poll-timeout 10m
tanzu package installed get service-bindings -n tap-install
kubectl get pods -n service-bindings

log "Installing Supply Chain Security Tools - Store"

cat > scst-store-values.yaml <<EOF
db_password: "PASSWORD-0123"
EOF

SCST_VERSION=$(packageVersion scst-store.tanzu.vmware.com)
tanzu package install metadata-store \
  --package-name scst-store.tanzu.vmware.com \
  --version $SCST_VERSION \
  --namespace tap-install \
  --values-file scst-store-values.yaml \
   --poll-timeout 10m

log "Installing Supply Chain Security Tools - Sign"

cat > scst-sign-values.yaml <<EOF
---
warn_on_unmatched: true
EOF

IPW_VERSION=$(packageVersion image-policy-webhook.signing.run.tanzu.vmware.com)
tanzu package install image-policy-webhook \
  --package-name image-policy-webhook.signing.run.tanzu.vmware.com \
  --version $IPW_VERSION \
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

kubectl delete secret image-pull-secret -n image-policy-system 2> /dev/null || true
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

echo "The cosign pod should be created without a warning"
kubectl run cosign --image=gcr.io/projectsigstore/cosign:v1.2.1 --restart=Never --command -- sleep 5
echo "The busybox pod should generate a warning"
kubectl run busybox --image=busybox --restart=Never -- sleep 5

kubectl delete pod cosign --force --grace-period=0 2> /dev/null || true
kubectl delete pod busybox --force --grace-period=0 2> /dev/null || true

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

(kubectl create namespace scan-link-system 2> /dev/null) || true
kubectl apply -f metadata-store-secret.yaml

SCAN_VERSION=$(packageVersion scanning.apps.tanzu.vmware.com)
tanzu package install scan-controller \
  --package-name scanning.apps.tanzu.vmware.com \
  --version $SCAN_VERSION \
  --namespace tap-install \
  --values-file scst-scan-controller-values.yaml \
  --poll-timeout 10m
tanzu package installed get scan-controller -n tap-install

log "Installing Supply Chain Security Tools - Scan (Grype Scanner)"

GRYPE_VERSION=$(packageVersion grype.scanning.apps.tanzu.vmware.com)
tanzu package install grype-scanner \
  --package-name grype.scanning.apps.tanzu.vmware.com \
  --version $GRYPE_VERSION \
  --namespace tap-install \
  --poll-timeout 10m
tanzu package installed get grype-scanner -n tap-install

log "Installing API portal"

APIP_VERSION=$(packageVersion api-portal.tanzu.vmware.com)
tanzu package install api-portal -n tap-install -p api-portal.tanzu.vmware.com -v $APIP_VERSION --poll-timeout 10m
tanzu package installed get api-portal -n tap-install

log "Installing Services Control Plane (SCP) Toolkit"

SCPT_VERSION=$(packageVersion scp-toolkit.tanzu.vmware.com)
tanzu package install scp-toolkit -n tap-install -p scp-toolkit.tanzu.vmware.com -v $SCPT_VERSION
tanzu package installed get scp-toolkit -n tap-install

# kubectl describe service/application-live-view-7000 -n tap-install
# kubectl describe service/application-live-view-5112 -n tap-install

log "Checking state of all packages"

tanzu package installed list --namespace tap-install -o json | \
  jq -r '.[] | (.name + " " .status)' | \
  while read package status
  do
    if [[ $status != "Reconcile succeeded" ]]
    then
      echo "ERROR: At least one package failed to reconcile" >&2
      tanzu package installed list --namespace tap-install
      exit 1
    fi
  done

log "Setting up secrets, accounts and roles for default developer namespace"

cat > developer-namespace-setup.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: tap-registry
  annotations:
    secretgen.carvel.dev/image-pull-secret: ""
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: e30K

---
apiVersion: v1
kind: Secret
metadata:
  name: registry-credentials
  annotations:
    secretgen.carvel.dev/image-pull-secret: ""
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: e30K

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: service-account # use value from "Install Default Supply Chain"
secrets:
  - name: registry-credentials
imagePullSecrets:
  - name: registry-credentials
  - name: tap-registry

---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kapp-permissions
  annotations:
    kapp.k14s.io/change-group: "role"
rules:
  - apiGroups:
      - servicebinding.io
    resources: ['servicebindings']
    verbs: ['*']
  - apiGroups:
      - serving.knative.dev
    resources: ['services']
    verbs: ['*']
  - apiGroups: [""]
    resources: ['configmaps']
    verbs: ['get', 'watch', 'list', 'create', 'update', 'patch', 'delete']

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kapp-permissions
  annotations:
    kapp.k14s.io/change-rule: "upsert after upserting role"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kapp-permissions
subjects:
  - kind: ServiceAccount
    name: service-account # use value from "Install Default Supply Chain"
EOF

kubectl apply -f developer-namespace-setup.yaml

log "Setting up port forwarding for App Accelerator (http://localhost:8877) ..."
kubectl port-forward service/acc-ui-server 8877:80 -n accelerator-system &
log "Setting up port forwarding for App Live View (http://localhost:5112) ..."
kubectl port-forward service/application-live-view-5112 5112:5112 -n tap-install &
