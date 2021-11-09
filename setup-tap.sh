#!/bin/bash
#
# Tanzu Application Platform installation script

TAP_VERSION=0.3.0

set -e

source $(dirname $0)/functions.sh

#####
##### Main code starts here
#####

DO_INIT=true
for arg in "$@"
do
  case "$arg" in
  --skip-init)
    DO_INIT=false
    ;;
  esac
done

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

Note that applications will be deployed in the 'apps' sub-domain of
your supplied domain. For example, if you use the domain 'tap.example.com'
then your applications will end up with DNS names such as
'my-awesome-app.default.apps.tap.example.com'.

The TAP GUI and Educates components will be placed under a 'sys'
sub-domain, for example, 'gui.sys.tap.example.com'.

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

This should eith be one of the following two built-in profiles:

  * dev-light
  * full

Or it can be a list of one or more of the following packages, separated
by spaces (values in brackets indicate prerequisites which will
alos be installed automatically by the script):

  * accelerator               [source-controller]
  * api-portal
  * appliveview
  * buildservice
  * cartographer              [source-controller]
  * cnrs
  * convention-controller
  * developer-conventions     [convention-controller]
  * image-policy-webhook
  * grype                     [scanning]
  * learningcenter
  * learningcenter-workshops  [learning-center
  * ootb-supply-chain-basic   [ootb-templates]
  * ootb-supply-chain-testing [tekton, ootb-templates]
  * ootb-supply-chain-testing-scanning
                              [tekton, scanning, ootb-templates]
  * ootb-templates            [convention-controller, cartographer]
  * scanning                  [grype]
  * service-bindings          [services-toolkit]
  * services-toolkit          [service-bindings]
  * signing (alias for image-policy-webhook)
  * source-controller         
  * spring-boot-conventions   [convention-controller]
  * tap-gui                   [appliveview]
  * tbs (alias for buildservice)
  * tekton

Note that the choice of supply chain (e.g. testing) will also cause
the matching ootb-supply-chain-* package and its dependencies
to be installed.
EOT

findOrPromptWithDefault INSTALL_PROFILE "Profile" "full"

validateAndEnableInstallationOptions

cat <<EOT
 
>>> GUI Catalog Info URL

The TAP GUI needs information about the components and systems which
it should display. This is done by providing a URL to a 'catalog-info.yaml'
file. The default value provided is a publicly accessible blank catalog.

EOT

findOrPromptWithDefault GUI_CATALOG_URL \
  "Catalog URL" \
  "https://github.com/ndwinton/tap-gui-blank-catalog/blob/main/catalog-info.yaml"

cat <<EOT

>>> Default supply chain

This should be one of the following: basic, testing, scanning or none

EOT

findOrPromptWithDefault SUPPLY_CHAIN "Supply chain" "basic"

validateAndEnableSupplyChainComponent
enablePreRequisites

banner "The following packages will be installed:" ${!ENABLED[*]}

### Set up (global, sigh ...) data used elsewhere

SYS_DOMAIN="sys.${DOMAIN}"
APPS_DOMAIN="apps.${DOMAIN}"
GUI_DOMAIN="gui.${SYS_DOMAIN}"

if isLocal
then
  CNR_PROVIDER="local"
  CNR_LOCAL_DNS="true"
  AA_SERVICE_TYPE='NodePort'
  ALV_SERVICE_TYPE='ClusterIP'
  GUI_SERVICE_TYPE='ClusterIP'
  # Can't use vcap.me for educates
  EDUCATES_DOMAIN="educates.$(hostname -I | cut -d' ' -f1).nip.io"
else
  CNR_PROVIDER=""
  CNR_LOCAL_DNS="false"
  AA_SERVICE_TYPE='LoadBalancer'
  ALV_SERVICE_TYPE='LoadBalancer'
  GUI_SERVICE_TYPE='LoadBalancer'
  EDUCATES_DOMAIN=educates.$SYS_DOMAIN
fi

if $DO_INIT
then
  deployKappController
  deploySecretgenController
  if ! isEnabled full dev-light
  then
    deployCertManager
    deployFluxCD
  fi
  createTapNamespace
  createTapRegistrySecret
  loadPackageRepository
fi

tanzu package available list --namespace tap-install

# If using the 'unbundled' profile these will configure
# and install the appropriate packages, otherwise they will
# just generate the config files

configureCloudNativeRuntimes
configureConventionController
configureSourceController
configureAppAccelerator
configureTanzuBuildService
configureChoreographer
configureOotbTemplates
configureOotbSupplyChains
configureDeveloperConventions
configureSpringBootConventions
configureAppLiveView
configureTapGui
configureLearningCenter
configureScstStore
configureSigning
configureScanning
configureApiPortal
configureTekton
configureServicesToolkit
configureServiceBindings

configureBuiltInProfiles

configureImageSigningPolicy


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
  banner "Setting up port forwarding for App Acclerator and App Live View (if present)"

  isEnabled accelerator && kubectl port-forward service/acc-ui-server 8877:80 -n accelerator-system &
  isEnabled appliveview && kubectl port-forward service/application-live-view-5112 5112:80 -n app-live-view &

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
