#!/bin/bash

set -e

function banner() {
  echo ""
  echo "###"
  echo "### $*"
  echo "###"
  echo ""
}

function message() {
  echo ">>> $*"
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

# Get the latest version of a package (assumes ordered by date)
function packageVersion() {
  tanzu package available list $1 -n tap-install -o json | jq -r '.[-1].version'
}

# Wait until there is no (non-error) output from a command
function waitForRemoval() {
  while [[ -n $("$@" 2> /dev/null || true) ]]
  do
    message "Waiting for resource to disappear ..."
    sleep 5
  done
}

# Updates or installs the latest version of a package
function installLatest() {
  local name=$1
  local package=$2
  local values=$3
  local timeout=${4:-10m}

  local version=$(packageVersion $package)

  tanzu package installed update --install \
    $name -p $package -v $version \
    -n tap-install \
    --poll-timeout $timeout \
    ${values:+-f} $values \

  tanzu package installed get $name -n tap-install
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

banner "Deploying kapp-controller"

kapp deploy -a kc -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/latest/download/release.yml -y
kubectl get deployment kapp-controller -n kapp-controller  -o yaml | grep kapp-controller.carvel.dev/version:

banner "Deploying secretgen-controller"

kapp deploy -a sg -f https://github.com/vmware-tanzu/carvel-secretgen-controller/releases/latest/download/release.yml -y
kubectl get deployment secretgen-controller -n secretgen-controller -o yaml | grep secretgen-controller.carvel.dev/version:

banner "Deploying cert-manager"

kapp deploy -a cert-manager -f https://github.com/jetstack/cert-manager/releases/download/v1.5.3/cert-manager.yaml -y
kubectl get deployment cert-manager -n cert-manager -o yaml | grep -m 1 'app.kubernetes.io/version: v'

banner "Deploying FluxCD source-controller"

(kubectl get ns flux-system 2> /dev/null) || \
  kubectl create namespace flux-system
(kubectl get clusterrolebinding default-admin 2> /dev/null) || \
kubectl create clusterrolebinding default-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=flux-system:default
kapp deploy -a flux-source-controller -n flux-system -y \
  -f https://github.com/fluxcd/source-controller/releases/download/v0.15.4/source-controller.crds.yaml \
  -f https://github.com/fluxcd/source-controller/releases/download/v0.15.4/source-controller.deployment.yaml

banner "Creating tap-install namespace"

(kubectl get ns tap-install 2> /dev/null) || \
  kubectl create ns tap-install

banner "Creating tap-registry imagepullsecret"

tanzu imagepullsecret delete tap-registry --namespace tap-install -y || true
waitForRemoval kubectl get secret tap-registry --namespace tap-install -o json

tanzu imagepullsecret add tap-registry \
  --username "$TN_USERNAME" --password "$TN_PASSWORD" \
  --registry registry.tanzu.vmware.com \
  --export-to-all-namespaces --namespace tap-install

banner "Removing any current TAP package repository"

tanzu package repository delete tanzu-tap-repository -n tap-install || true
waitForRemoval tanzu package repository get tanzu-tap-repository -n tap-install -o json

banner "Adding TAP package repository"

tanzu package repository add tanzu-tap-repository \
    --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$TAP_VERSION \
    --namespace tap-install
tanzu package repository get tanzu-tap-repository --namespace tap-install
while [[ $(tanzu package available list --namespace tap-install -o json) == '[]' ]]
do
  message "Waiting for packages ..."
  sleep 5
done
tanzu package available list --namespace tap-install

banner "Deploying Cloud Native Runtime ..."

cat > cnr-values.yaml <<EOF
---
provider: "local"   

local_dns:
  enable: "true"
  domain: "vcap.me"
EOF

installLatest cloud-native-runtimes cnrs.tanzu.vmware.com cnr-values.yaml

# For more detailed information on the progress of a package install, use
# something like the following:
#  kapp inspect -n tap-install -a cloud-native-runtimes-ctrl -y

banner "Setting CNR (knative) domain to vcap.me ..."

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

banner "Deploying App Accelerator ..."
cat > app-accelerator-values.yaml <<EOF
---
server:
  # Set this service_type to "NodePort" for local clusters like minikube.
  service_type: "NodePort"
  watched_namespace: "default"
EOF

installLatest app-accelerator \
  accelerator.apps.tanzu.vmware.com \
  app-accelerator-values.yaml
kubectl get pods -n accelerator-system

banner "Installing Convention Controller"

installLatest convention-controller controller.conventions.apps.tanzu.vmware.com
kubectl get pods -n conventions-system

banner "Installing Source Controller"

installLatest source-controller controller.source.apps.tanzu.vmware.com
kubectl get pods -n source-system

banner "Installing Tanzu Build Service"

cat > tbs-values.yaml <<EOF
---
kp_default_repository: "$REGISTRY"
kp_default_repository_username: "$REG_USERNAME"
kp_default_repository_password: "$REG_PASSWORD"
tanzunet_username: "$TN_USERNAME"
tanzunet_password: "$TN_PASSWORD"
EOF

installLatest tbs buildservice.tanzu.vmware.com tbs-values.yaml 30m

banner "Installing Supply Chain Choreographer (Cartographer)"

installLatest cartographer cartographer.tanzu.vmware.com

banner "Creating Default Supply Chain"

cat > default-supply-chain-values.yaml <<EOF
---
registry:
  server: "$REG_HOST"
  repository: "${REGISTRY##*/}"
service_account: service-account
EOF

tanzu imagepullsecret delete registry-credentials -y || true
waitForRemoval kubectl get secret registry-credentials -o json

tanzu imagepullsecret add registry-credentials \
  --registry "$REG_HOST" \
  --username "$REG_USERNAME" \
  --password "$REG_PASSWORD" \
  --export-to-all-namespaces || true

installLatest default-supply-chain \
  default-supply-chain.tanzu.vmware.com \
  default-supply-chain-values.yaml

banner "Installing Developer Conventions"

installLatest developer-conventions developer-conventions.tanzu.vmware.com

banner "Installing App Live View"

cat > app-live-view-values.yaml <<EOF
---
connector_namespaces: [default]
server_namespace: app-live-view
EOF

(kubectl get ns app-live-view 2> /dev/null) || \
  kubectl create ns app-live-view

installLatest app-live-view \
  appliveview.tanzu.vmware.com \
  app-live-view-values.yaml
kubectl get pods -n app-live-view

banner "Installing Service Bindings"

installLatest service-bindings service-bindings.labs.vmware.com
kubectl get pods -n service-bindings

banner "Installing Supply Chain Security Tools - Store"

cat > scst-store-values.yaml <<EOF
---
db_password: "PASSWORD-0123"
EOF

installLatest metadata-store \
  scst-store.tanzu.vmware.com \
  scst-store-values.yaml

banner "Installing Supply Chain Security Tools - Sign"

cat > scst-sign-values.yaml <<EOF
---
warn_on_unmatched: true
EOF

installLatest image-policy-webhook \
  image-policy-webhook.signing.run.tanzu.vmware.com \
  scst-sign-values.yaml

banner "Creating registry-credentials service account and image pull secret"

kubectl delete secret image-pull-secret -n image-policy-system 2> /dev/null || true
waitForRemoval kubectl get secret image-pull-secret -n image-policy-system -o json
kubectl create secret docker-registry image-pull-secret \
  --docker-server="$REG_HOST" \
  --docker-username="$REG_USERNAME" \
  --docker-password="$REG_PASSWORD" \
  --namespace image-policy-system

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: registry-credentials
  namespace: image-policy-system
imagePullSecrets:
- name: image-pull-secret
EOF

banner "Creating basic ClusterImagePolicy"

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

banner "Testing image signing policy"

kubectl delete pod cosign --force --grace-period=0 2> /dev/null || true
kubectl delete pod busybox --force --grace-period=0 2> /dev/null || true

message "The cosign pod should be created without a warning"
kubectl run cosign --image=gcr.io/projectsigstore/cosign:v1.2.1 --restart=Never --command -- sleep 5

message "The busybox pod should generate a warning"
kubectl run busybox --image=busybox --restart=Never -- sleep 5

kubectl delete pod cosign --force --grace-period=0 2> /dev/null || true
kubectl delete pod busybox --force --grace-period=0 2> /dev/null || true

banner "Installing Supply Chain Security Tools - Scan"

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

installLatest scan-controller \
  scanning.apps.tanzu.vmware.com \
  scst-scan-controller-values.yaml

banner "Installing Supply Chain Security Tools - Scan (Grype Scanner)"

installLatest grype-scanner grype.scanning.apps.tanzu.vmware.com

banner "Installing API portal"

installLatest api-portal api-portal.tanzu.vmware.com

banner "Installing Services Control Plane (SCP) Toolkit"

installLatest scp-toolkit scp-toolkit.tanzu.vmware.com

banner "Checking state of all packages"

tanzu package installed list --namespace tap-install -o json | \
  jq -r '.[] | (.name + " " + .status)' | \
  while read package status
  do
    if [[ $status != "Reconcile succeeded" ]]
    then
      echo "ERROR: At least one package failed to reconcile" >&2
      tanzu package installed list --namespace tap-install
      exit 1
    fi
  done

banner "Setting up secrets, accounts and roles for default developer namespace"

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

message "Setting up port forwarding for App Accelerator (http://localhost:8877) ..."
kubectl port-forward service/acc-ui-server 8877:80 -n accelerator-system &

message "Setting up port forwarding for App Live View (http://localhost:5112) ..."
kubectl port-forward service/application-live-view-5112 5112:5112 -n tap-install &

message "For 'pure' knative deployment in a namespace run:"
message "  kubectl patch serviceaccount default -p '{\"imagePullSecrets\": [{\"name\": \"registry-credentials\"}]}'"

banner "Finished"