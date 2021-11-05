#!/bin/bash
#
# Tanzu Application Platform installation script

TAP_VERSION=0.3.0-build.8

set -e

DO_INIT=true
for arg in "$@"
do
  case "$arg" in
  --skip-init)
    DO_INIT=false
    ;;
  esac
done

function banner() {
  local line
  echo ""
  echo "###"
  for line in "$@"
  do
    echo "### $line"
  done
  echo "###"
  echo ""
}

function message() {
  local line
  for line in "$@"
  do
    echo ">>> $line"
  done
}

function findOrPrompt() {
  local varName="$1"
  local prompt="$2"

  if [[ -z "${!varName}" ]]
  then
    echo "$varName not found in environment"
    read -p "$prompt: " $varName
  else
    echo "Value for $varName found in environment"
  fi
}

function findOrPromptWithDefault() {
  local varName="$1"
  local prompt="$2"
  local default="$3"

  findOrPrompt "$varName" "$prompt [$default]"
  if [[ -z "${!varName}" ]]
  then
    export ${varName}="$default"
  fi
}

# Get the latest version of a package
function latestVersion() {
  tanzu package available list $1 -n tap-install -o json | \
    jq -r 'sort_by(."released-at")[-1].version'
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

  local version=$(latestVersion $package)

  logRun tanzu package installed update --install \
    $name -p $package -v $version \
    -n tap-install \
    --poll-timeout $timeout \
    ${values:+-f} $values

  tanzu package installed get $name -n tap-install
}

function logRun() {
  message "Running: $*"
  "$@"
}

function isLocal() {
  [[ $DOMAIN == "vcap.me" ]]
}

function deployKappController() {
  banner "Deploying kapp-controller"

  # Check if we appear to be running on TCE or TKG.
  # If so, there will need to be some manual steps taken to delete the
  # existing kapp-controller

  if kubectl get deployment kapp-controller -n tkg-system 2> /dev/null
  then
    banner "You appear to be running on a TCE or TKGcluster." \
      "You must follow the instructions in the documentation to delete the current" \
      "kapp-controller deployment before re-running this script." \
      "" \
      "The documentation for TCE is at:" \
      "https://docs-staging.vmware.com/en/VMware-Tanzu-Application-Platform/0.3/tap-0-3/GUID-install-tce.html" \
      "" \
      "The documentation for TKG is at:" \
      "https://docs-staging.vmware.com/en/VMware-Tanzu-Application-Platform/0.3/tap-0-3/GUID-install-tkg.html"

      exit 1
  fi

  kapp deploy -a kc -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/latest/download/release.yml -y
  kubectl get deployment kapp-controller -n kapp-controller  -o yaml | grep kapp-controller.carvel.dev/version:
}

function deploySecretgenController() {
  banner "Deploying secretgen-controller"

  kapp deploy -a sg -f https://github.com/vmware-tanzu/carvel-secretgen-controller/releases/latest/download/release.yml -y
  kubectl get deployment secretgen-controller -n secretgen-controller -o yaml | grep secretgen-controller.carvel.dev/version:
}

function createTapNamespace() {

  banner "Creating tap-install namespace"

  (kubectl get ns tap-install 2> /dev/null) || \
    kubectl create ns tap-install
}

function createTapRegistrySecret() {

  banner "Creating tap-registry registry secret"

  tanzu secret registry delete tap-registry --namespace tap-install -y || true
  waitForRemoval kubectl get secret tap-registry --namespace tap-install -o json

  tanzu secret registry add tap-registry \
    --username "$TN_USERNAME" --password "$TN_PASSWORD" \
    --server registry.tanzu.vmware.com \
    --export-to-all-namespaces --namespace tap-install --yes
}

function loadPackageRepository() {
  banner "Removing any current TAP package repository"

  tanzu package repository delete tanzu-tap-repository -n tap-install --yes || true
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
}

cat <<EOT
WARNING!

This script is not officially supported.
It will contribute to global warming.
It may fail in unexpected ways.
It could damage your system.
It might ruin your day.
Use at your own risk.

Enjoy :-)
---------

This script will set up Tanzu Application Platform ($TAP_VERSION) on a machine
with the necessary tooling (Carvel tools, kpack and knative clients)
already installed, along with a Kubernetes cluster.

You will need an account on the Tanzu Network (aka PivNet) and an account
for a container registry, such as DockerHub or Harbor.

Values for various configuration parameters will be taken from
environment variables, if set. If they are not present then they
will be prompted for.

>>> Tanzu Network credentials

EOT

findOrPrompt TN_USERNAME "Tanzu Network Username"
findOrPrompt TN_PASSWORD "Tanzu Network Password (will be echoed)"

cat <<EOT

>>> Container Registry

The container registry should be something like 'myuser/tap' for DockerHub or
'harbor-repo.example.com/myuser/tap' for an internal registry.

EOT
findOrPrompt REGISTRY "Container Registry"
findOrPrompt REG_USERNAME "Registry Username"
findOrPrompt REG_PASSWORD "Registry Password (will be echoed)"

cat <<EOT

>>> Application domain

The default value for the domain to be used to host applications
is 'vcap.me'. If you use this value then the will result in a purely
local TAP installation, as all 'vcap.me' names resolve to the
localhost address. If you use anything other than 'vcap.me' then
a load-balancer will be created and you will have to map lookups
for the domain to the address of that load-balancer.

EOT

findOrPromptWithDefault DOMAIN "Domain" "vcap.me" 

REG_HOST=${REGISTRY%%/*}
REG_BASE=${REGISTRY#*.*/}
if [[ $REG_HOST != *.* ]]
then
  # Using DockerHub
  REG_HOST='index.docker.io'
  REG_BASE=${REGISTRY%%/*}
  REGISTRY="$REG_HOST/$REGISTRY"
fi

cat <<EOT

>>> Installation profile

This should be one of the following:

dev-light - the "Developer Light" profile
full - a full TAP installation (the default)

EOT

findOrPromptWithDefault INSTALL_PROFILE "Profile" "full"

case "$INSTALL_PROFILE" in
full|dev-light)
  ;;
*)
  echo "ERROR: Invalid value for INSTALL_PROFILE: $INSTALL_PROFILE"
  exit 1
esac

if $DO_INIT
then
  deployKappController

  deploySecretgenController

  createTapNamespace

  createTapRegistrySecret

  loadPackageRepository
fi

tanzu package available list --namespace tap-install

banner "Deploying TAP Profile: ${INSTALL_PROFILE} ..."

SYS_DOMAIN="sys.${DOMAIN}"
APPS_DOMAIN="apps.${DOMAIN}"
GUI_DOMAIN="gui.${SYS_DOMAIN}"

if isLocal
then
  CNR_PROVIDER="local"
  CNR_LOCAL_DNS="true"
  AA_SERVICE_TYPE='NodePort'
  ALV_SERVICE_TYPE='ClusterIP'
  # Can't use vcap.me for educates
  EDUCATES_DOMAIN="educates.$(hostname -I | cut -d' ' -f1).nip.io"
else
  CNR_PROVIDER=""
  CNR_LOCAL_DNS="false"
  AA_SERVICE_TYPE='LoadBalancer'
  ALV_SERVICE_TYPE='LoadBalancer'
  EDUCATES_DOMAIN=educates.$SYS_DOMAIN
fi

cat > tap-values.yaml <<EOF
profile: ${INSTALL_PROFILE}

buildservice:
  tanzunet_username: "${TN_USERNAME}"
  tanzunet_password: "${TN_PASSWORD}"
  kp_default_repository: "$REGISTRY"
  kp_default_repository_username: "$REG_USERNAME"
  kp_default_repository_password: |-
$(echo "${REG_PASSWORD}" | sed -e 's/^/    /')

cnrs:
  provider: ${CNR_PROVIDER}
  local_dns:
    enable: "${CNR_LOCAL_DNS}"
    domain: "${APPS_DOMAIN}"

accelerator:
  server:
    service_type: "${AA_SERVICE_TYPE}"
    watched_namespace: "default"

appliveview:
  connector_namespaces: [default]
  service_type: "${ALV_SERVICE_TYPE}"

ootb_supply_chain_basic:
  service_account: default
  registry:
    server: "${REG_HOST}"
    repository: "${REG_BASE}"

ootb_supply_chain_testing:
  service_account: default
  registry:
    server: "${REG_HOST}"
    repository: "${REG_BASE}"

ootb_supply_chain_testing_scanning:
  service_account: default
  registry:
    server: "${REG_HOST}"
    repository: "${REG_BASE}"

learningcenter:
  ingressDomain: ${EDUCATES_DOMAIN}"

tap_gui:  # Minimal setup
  namespace: tap-gui
  service_type: LoadBalancer
  app-config:
    app:
      baseUrl: http://${GUI_DOMAIN}:7000
    #
    # There are default public GitHub and GitLab integrations
    # You only need to add values such as the following if you want
    # to access private repositories
    #
    # integrations:
    #   github:
    #     - host: github.com
    #       token: <GITHUB-TOKEN>
    #   gitlab:
    #     - host: <GITLAB-HOST>
    #       apiBaseUrl: https://<GITLAB-URL>/api/v4
    #       token: <GITLAB-TOKEN>
    #
    catalog:
      locations:
        # REPLACE THE FOLLOWING URL WITH YOUR OWN CATALOG
        - type: url
          target: https://raw.githubusercontent.com/ndwinton/tap-gui-blank-catalog/main/catalog-info.yaml
    backend:
        baseUrl: https://${GUI_DOMAIN}:7000
        cors:
            origin: https://${GUI_DOMAIN}:7000

EOF

installLatest tap tap.tanzu.vmware.com tap-values.yaml 30m

banner "Setting CNR (knative) domain to $DOMAIN ..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
data:
  $APPS_DOMAIN: |
kind: ConfigMap
metadata:
  name: config-domain
  namespace: knative-serving
EOF

banner "Setting up secrets, accounts and roles for default developer namespace"

tanzu secret registry delete registry-credentials -y || true
waitForRemoval kubectl get secret registry-credentials -o json

# The following is a workaround for a Beta 2/3 bug
if [[ "$REG_HOST" == "index.docker.io" ]]
then
  REG_CRED_HOST="https://index.docker.io/v1/"
else
  REG_CRED_HOST=$REG_HOST
fi

tanzu secret registry add registry-credentials \
  --server "$REG_CRED_HOST" \
  --username "$REG_USERNAME" \
  --password "$REG_PASSWORD" \
  --namespace default || true

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
kind: ServiceAccount
metadata:
  name: default # maybe "service-account"?
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
      - services.tanzu.vmware.com
    resources: ['resourceclaims']
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
    name: default
EOF

kubectl apply -f developer-namespace-setup.yaml

# Allow use of Knative directly in default namespace

kubectl patch serviceaccount default \
  -p '{"imagePullSecrets": [{"name": "registry-credentials"}, {"name": "tap-registry"}]}'

if isLocal
then
  banner "Setting up port forwarding for App Acclerator and App Live View"

  kubectl port-forward service/acc-ui-server 8877:80 -n accelerator-system &
  kubectl port-forward service/application-live-view-5112 5112:80 -n app-live-view &

  cat <<EOF

# Port forwarding for App Accelerator and App Live View has been set up,
# but if you need to restart it, run the following commands.
#
# To set up port forwarding for App Accelerator (http://localhost:8877) run:"

  kubectl port-forward service/acc-ui-server 8877:80 -n accelerator-system &

# To set up port forwarding for App Live View (http://localhost:5112) run:"

  kubectl port-forward service/application-live-view-5112 5112:80 -n app-live-view &

EOF
else

  ENVOY_IP=$(kubectl get svc envoy -n contour-external -o jsonpath='{ .status.loadBalancer.ingress[0].ip }')
  ACCELERATOR_IP=$(kubectl get svc acc-ui-server -n accelerator-system -o jsonpath='{ .status.loadBalancer.ingress[0].ip }')
  LIVE_VIEW_IP=$(kubectl get svc application-live-view-5112 -n app-live-view -o jsonpath='{ .status.loadBalancer.ingress[0].ip }')
  GUI_IP=$(kubectl get svc server -n tap-gui -o jsonpath='{ .status.loadBalancer.ingress[0].ip }')
  cat <<EOF

###
### Applications deployed in TAP will run at ${ENVOY_IP}
### Please configure DNS for *.${APPS_DOMAIN} to point to that address
###
### The TAP GUI will run at http://${GUI_DOMAIN}:7000
### Please configure DNS for $GUI_DOMAIN to map to ${GUI_IP}
###

### App Accelerator is running at http://${ACCELERATOR_IP}

### App Live View is running at http://${LIVE_VIEW_IP}

EOF
fi

cat <<EOF

###
### To set up TAP services for use in a namespace run the following:"
###

  kubectl apply -n YOUR-NAMESPACE -f $PWD/developer-namespace-setup.yaml

# Add the following for 'pure' knative (kn command):

  kubectl patch serviceaccount default \
    -n YOUR-NAMESPACE
    -p '{"imagePullSecrets": [{"name": "registry-credentials"}, {"name": "tap-registry"}]}'

EOF

banner "Checking state of all packages"

tanzu package installed list --namespace tap-install -o json | \
  jq -r '.[] | (.name + " " + .status)' | \
  while read package status
  do
    if [[ "$status" != "Reconcile succeeded" ]]
    then
      message "ERROR: At least one package ($package) failed to reconcile ($status)"
      exit 1
    fi
  done

banner "Setup complete."
