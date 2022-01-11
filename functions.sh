#!/usr/bin/env bash


function banner {
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

function message {
  local line
  for line in "$@"
  do
    echo ">>> $line"
  done
}

function fatal {
  message "ERROR: $*"
  exit 1
}

function findOrPrompt {
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

function findOrPromptWithDefault {
  local varName="$1"
  local prompt="$2"
  local default="$3"

  findOrPrompt "$varName" "$prompt [$default]"
  if [[ -z "${!varName}" ]]
  then
    export ${varName}="$default"
  fi
}

function requireValue {
  local varName

  for varName in $*
  do
    if [[ -z "${!varName}" ]]
    then
      fatal "Variable $varName is missing at line $(caller)"
    fi
  done
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
  requireValue DOMAIN

  [[ $DOMAIN == "vcap.me" ]]
}

function unbundled() {
  requireValue INSTALL_PROFILE

  [[ $INSTALL_PROFILE == 'unbundled' ]]
}

function deployKappAndSecretgenControllers {
  checkForTCETKG

  banner "Downloading kapp + secretgen configuration bundle"

  export IMGPKG_USERNAME="$TN_USERNAME"
  export IMGPKG_PASSWORD="$TN_PASSWORD"

  local tag=$(imgpkg tag list -i registry.tanzu.vmware.com/tanzu-cluster-essentials/cluster-essentials-bundle --json | \
    jq -r '.Tables[0].Rows[].name' | \
    sed -ne '/image-locations/{
      s/\.image-locations.*$//
      s/-/:/
      p
    }' | tail -n 1)
  local bundle="registry.tanzu.vmware.com/tanzu-cluster-essentials/cluster-essentials-bundle@${tag}"

  rm -rf ./bundle
  imgpkg pull -b $bundle -o ./bundle/

  export YTT_registry__server=registry.tanzu.vmware.com
  export YTT_registry__username="$TN_USERNAME"
  export YTT_registry__password="$TN_PASSWORD"

  message "Creating namespace $ns_name"

  local ns_name=tanzu-cluster-essentials
  (kubectl get ns $ns_name 2> /dev/null) || \
    kubectl create ns $ns_name

  banner "Deploying kapp-controller"

  ytt -f ./bundle/kapp-controller/config/ -f ./bundle/registry-creds/ --data-values-env YTT --data-value-yaml kappController.deployment.concurrency=10 \
	  | kbld -f- -f ./bundle/.imgpkg/images.yml \
	  | kapp deploy -a kapp-controller -n $ns_name -f- --yes

  kubectl get deployment kapp-controller -n kapp-controller -o yaml | grep kapp-controller.carvel.dev/version:

  banner "Deploying secretgen-controller"
  ytt -f ./bundle/secretgen-controller/config/ -f ./bundle/registry-creds/ --data-values-env YTT \
	  | kbld -f- -f ./bundle/.imgpkg/images.yml \
	  | kapp deploy -a secretgen-controller -n $ns_name -f- --yes

  kubectl get deployment secretgen-controller -n secretgen-controller -o yaml | grep secretgen-controller.carvel.dev/version:
}

function checkForTCETKG {
  if kubectl get deployment kapp-controller -n tkg-system 2> /dev/null
  then
    banner "You appear to be running on a TCE or TKG cluster." \
      "You must follow the instructions in the documentation to delete the current" \
      "kapp-controller deployment before re-running this script." \
      "" \
      "The documentation for TCE is at:" \
      "https://docs.vmware.com/en/Tanzu-Application-Platform/0.4/tap/GUID-install-tce.html" \
      "" \
      "The documentation for TKG is at:" \
      "https://docs.vmware.com/en/Tanzu-Application-Platform/0.4/tap/GUID-install-tkg.html"

      fatal "Cannot continue"
  fi
}

function deployKappController() {
  banner "Deploying kapp-controller"

  # Check if we appear to be running on TCE or TKG.
  # If so, there will need to be some manual steps taken to delete the
  # existing kapp-controller

  if kubectl get deployment kapp-controller -n tkg-system 2> /dev/null
  then
    banner "You appear to be running on a TCE or TKG cluster." \
      "You must follow the instructions in the documentation to delete the current" \
      "kapp-controller deployment before re-running this script." \
      "" \
      "The documentation for TCE is at:" \
      "https://docs.vmware.com/en/Tanzu-Application-Platform/0.4/tap/GUID-install-tce.html" \
      "" \
      "The documentation for TKG is at:" \
      "https://docs.vmware.com/en/Tanzu-Application-Platform/0.4/tap/GUID-install-tkg.html"

      fatal "Cannot continue"
  fi

  kapp deploy -a kc -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/latest/download/release.yml -y
  kubectl get deployment kapp-controller -n kapp-controller  -o yaml | grep kapp-controller.carvel.dev/version:
}

function createTapNamespace() {

  banner "Creating tap-install namespace"

  (kubectl get ns tap-install 2> /dev/null) || \
    kubectl create ns tap-install
}

function createTapRegistrySecret {
  requireValue TN_USERNAME TN_PASSWORD

  banner "Creating tap-registry registry secret"

  tanzu secret registry delete tap-registry --namespace tap-install -y || true
  waitForRemoval kubectl get secret tap-registry --namespace tap-install -o json

  tanzu secret registry add tap-registry \
    --username "$TN_USERNAME" --password "$TN_PASSWORD" \
    --server registry.tanzu.vmware.com \
    --export-to-all-namespaces --namespace tap-install --yes
}

function loadPackageRepository {
  requireValue TAP_VERSION

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

function embedYaml {
  cat $* | sed -e '/^---/d; s/^/  /;'
}

declare -A ENABLED

function isEnabled {
  local profile

  for profile in $*
  do
    if ${ENABLED[$profile]:-false}
    then
      return 0
    fi
  done
  return 1
}

function validateAndEnableInstallationOptions {
  local value

  requireValue INSTALL_PROFILE

  for value in $INSTALL_PROFILE
  do
    case $value in
    accelerator) ;;
    api-portal) ;;
    appliveview) ;;
    buildservice) ;;
    cartographer) ;;
    cnrs) ;;
    conventions-controller) ;;
    convention-controller) ;; # Alias for above
    dev)
      message "WARNING: The 'dev' profile has been replaced by 'light' -- assuming 'light'"
      value=light
      ;;
    developer-conventions) ;;
    full) ;;
    image-policy-webhook) ;;
    grype) ;;
    learningcenter) ;;
    learningcenter-workshops) ;;
    light) ;;
    ootb-supply-chain-basic) ;;
    ootb-supply-chain-testing) ;;
    ootb-supply-chain-testing-scanning) ;;
    ootb-templates) ;;
    scanning) ;;
    service-bindings) ;;
    services-toolkit) ;;
    signing) ;;
    source-controller) ;;
    spring-boot-conventions) ;;
    tap-gui) ;;
    tbs) ;;
    tekton) ;;
    *)
      fatal "Invalid INSTALL_PROFILE component: $value"
      ;;
    esac

    ENABLED[$value]=true
  done

  if isEnabled full light && [[ ${#ENABLED[*]} != 1 ]]
  then
    fatal "'full' and 'light' must not be mixed with any other installation profiles"
  fi
  return 0
}

function validateAndEnableSupplyChainComponent {
  requireValue SUPPLY_CHAIN

  validateAndEnableExtraSupplyChain

  case $SUPPLY_CHAIN in
  basic|testing|scanning)
    isEnabled full light && return 0
    ;;
  none)
    if isEnabled full light
    then
      message "Supply chain type cannot be 'none' for 'full' or 'light' profiles -- using 'basic'"
      SUPPLY_CHAIN='basic'
      return 0
    fi
    ;;
  *)
    fatal "Invalid supply-chain value: $SUPPLY_CHAIN"
    ;;
  esac

  case $SUPPLY_CHAIN in
  basic)
    ENABLED[ootb-supply-chain-basic]=true
    ;;
  testing)
    ENABLED[ootb-supply-chain-testing]=true
    ;;
  scanning)
    ENABLED[ootb-supply-chain-testing-scanning]=true
    ;;
  esac

  return 0
}

function validateAndEnableExtraSupplyChain {
    requireValue SUPPLY_CHAIN EXTRA_SUPPLY_CHAIN

    case $EXTRA_SUPPLY_CHAIN in
  basic)
    ENABLED[ootb-supply-chain-basic]=true
    ;;
  testing)
    [[ "$SUPPLY_CHAIN" == "scanning" || "$SUPPLY_CHAIN" == "testing_scanning" ]] && \
      fatal "Cannot enable both 'testing' and 'scanning' supply chains"
    ENABLED[ootb-supply-chain-testing]=true
    ;;
  scanning|testing_scanning)
    [[ "$SUPPLY_CHAIN" == "testing" ]] && \
      fatal "Cannot enable both 'testing' and 'scanning' supply chains"
    ENABLED[ootb-supply-chain-testing-scanning]=true
    ;;
  esac

}

declare -A PRE_REQ
PRE_REQ[accelerator]="source-controller"
PRE_REQ[appliveview]="conventions-controller"
PRE_REQ[cartographer]="source-controller"
PRE_REQ[developer-conventions]="conventions-controller"
PRE_REQ[learningcenter-workshops]="learningcenter"
PRE_REQ[ootb-templates]="conventions-controller cartographer ${PRE_REQ[cartographer]}"
PRE_REQ[ootb-supply-chain-basic]="ootb-templates ${PRE_REQ[ootb-templates]}"
PRE_REQ[ootb-supply-chain-testing]="tekton ootb-templates ${PRE_REQ[ootb-templates]}"
PRE_REQ[ootb-supply-chain-testing-scanning]="tekton scanning ootb-templates ${PRE_REQ[ootb-templates]}"
PRE_REQ[scanning]="grype"
PRE_REQ[grype]="scanning"
PRE_REQ[service-bindings]="services-toolkit"
PRE_REQ[services-toolkit]="service-bindings"
PRE_REQ[spring-boot-conventions]="conventions-controller"

function enablePreRequisites {
  local initial=${!ENABLED[*]}
  local package

  for package in $initial
  do
    for preReq in ${PRE_REQ[$package]}
    do
      ENABLED[$preReq]=true
    done
  done
}

function configureCloudNativeRuntimes {
  requireValue CNR_LOCAL_DNS APPS_DOMAIN

  if [[ "${CNR_PROVIDER}" == "local" ]]
  then
    cat > cnrs-values.yaml <<EOF
---
domain_name: "${APPS_DOMAIN}"
provider: "${CNR_PROVIDER}"
local_dns:
  enable: "${CNR_LOCAL_DNS}"
  domain: "${APPS_DOMAIN}"
ingress:
  reuse_crds: true
  external:
    namespace: tanzu-system-ingress
EOF
  else
    cat > cnrs-values.yaml <<EOF
---
domain_name: "${APPS_DOMAIN}"
ingress:
  reuse_crds: true
  external:
    namespace: tanzu-system-ingress
  internal:
    namespace: tanzu-system-ingress
EOF
  fi

  if isEnabled cnrs
  then
    banner "Installing Cloud Native Runtimes"

    installLatest cloud-native-runtimes cnrs.tanzu.vmware.com cnrs-values.yaml
  fi
}

function configureConventionsController {
  if isEnabled conventions-controller convention-controller
  then
    banner "Installing Conventions Controller"

    installLatest conventions-controller controller.conventions.apps.tanzu.vmware.com
    kubectl get pods -n conventions-system
  fi
}

function configureSourceController {
  if isEnabled source-controller
  then    
    banner "Installing Source Controller"

    installLatest source-controller controller.source.apps.tanzu.vmware.com
    kubectl get pods -n source-system

    banner "Installing FluxCD Source Controller"
    installLatest fluxcd-source-controller fluxcd.source.controller.tanzu.vmware.com
    kubectl get pods -n flux-system
  fi
}

function configureAppAccelerator {
  requireValue AA_SERVICE_TYPE

  cat > app-accelerator-values.yaml <<EOF
---
server:
  service_type: "${AA_SERVICE_TYPE}"
  watched_namespace: "default"
EOF

  if isEnabled accelerator
  then
    banner "Installing App Accelerator"

    installLatest app-accelerator \
    accelerator.apps.tanzu.vmware.com \
    app-accelerator-values.yaml
    kubectl get pods -n accelerator-system
  fi
}

function configureTanzuBuildService {
  requireValue TN_USERNAME TN_PASSWORD REGISTRY REG_USERNAME REG_PASSWORD

  cat > tbs-values.yaml <<EOF
---
tanzunet_username: "${TN_USERNAME}"
tanzunet_password: "${TN_PASSWORD}"
kp_default_repository: "$REGISTRY"
kp_default_repository_username: "$REG_USERNAME"
kp_default_repository_password: |-
$(echo "${REG_PASSWORD}" | sed -e 's/^/  /')
EOF

  if isEnabled buildservice tbs
  then
    banner "Installing Tanzu Build Service"

    installLatest tbs buildservice.tanzu.vmware.com tbs-values.yaml 30m
  fi
}

function configureChoreographer {
  if isEnabled cartographer \
    choreographer \
    ootb-templates \
    ootb-supply-chain-basic \
    ootb-supply-chain-testing \
    ootb-supply-chain-testing-scanning
  then
    banner "Installing Supply Chain Choreographer (Cartographer)"

    installLatest cartographer cartographer.tanzu.vmware.com
  fi
}

function configureOotbTemplates {
  if isEnabled ootb-templates
  then
    banner "Installing OOTB Templates"

    installLatest ootb-templates ootb-templates.tanzu.vmware.com
  fi
}

function configureOotbSupplyChains {
  requireValue REG_HOST REG_BASE

  cat > ootb-supply-chain-values.yaml <<EOF
---
service_account: default
registry:
  server: "${REG_HOST}"
  repository: "${REG_BASE}"
gitops:
  ssh_secret: ""
EOF

  if isEnabled ootb-supply-chain-basic
  then
    banner "Installing OOTB Supply Chain: basic"

    installLatest ootb-supply-chain-basic \
      ootb-supply-chain-basic.tanzu.vmware.com \
      ootb-supply-chain-values.yaml
  fi

  if isEnabled ootb-supply-chain-testing
  then
    banner "Installing OOTB Supply Chain: testing"

    installLatest ootb-supply-chain-testing \
      ootb-supply-chain-testing.tanzu.vmware.com \
      ootb-supply-chain-values.yaml
  fi

  if isEnabled ootb-supply-chain-testing-scanning
  then
    banner "Installing OOTB Supply Chain: scanning"

    installLatest ootb-supply-chain-testing-scanning \
      ootb-supply-chain-testing-scanning.tanzu.vmware.com \
      ootb-supply-chain-values.yaml
  fi
}

function configureDeveloperConventions {
  if isEnabled developer-conventions
  then
    banner "Installing Developer Conventions"

    installLatest developer-conventions developer-conventions.tanzu.vmware.com
  fi
}

function configureSpringBootConventions {
  if isEnabled spring-boot-conventions
  then
    banner "Installing Spring Boot Conventions"

    installLatest spring-boot-conventions spring-boot-conventions.tanzu.vmware.com
  fi
}

function configureAppLiveView {
  requireValue ALV_SERVICE_TYPE

  cat > app-live-view-values.yaml <<EOF
---
connector_namespaces: [default]
service_type: "${ALV_SERVICE_TYPE}"
EOF

  if isEnabled appliveview
  then
    installLatest appliveview \
      run.appliveview.tanzu.vmware.com \
      app-live-view-values.yaml

    installLatest appliveview-conventions \
      build.appliveview.tanzu.vmware.com
  fi
}

function configureTapGui {
  requireValue GUI_DOMAIN GUI_SERVICE_TYPE GUI_CATALOG_URL

  cat > tap-gui-values.yaml <<EOF
---
namespace: tap-gui
service_type: ${GUI_SERVICE_TYPE}
app_config:
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
      - type: url
        target: ${GUI_CATALOG_URL}
  backend:
      baseUrl: http://${GUI_DOMAIN}:7000
      cors:
          origin: http://${GUI_DOMAIN}:7000
  

EOF

  if isEnabled tap-gui
  then
    banner "Installing TAP GUI"

    installLatest tap-gui tap-gui.tanzu.vmware.com tap-gui-values.yaml
  fi
}

function configureLearningCenter {
  cat > learning-center-values.yaml <<EOF
---
ingressDomain: ${EDUCATES_DOMAIN}
EOF

  if isEnabled learningcenter
  then
    banner "Installing Learning Center"
    installLatest learningcenter \
      learningcenter.tanzu.vmware.com \
      learning-center-values.yaml
  fi

  if isEnabled learningcenter-workshops
  then
    banner "Installing Learning Center Workshops"
    installLatest learningcenter-workshops \
      workshops.learningcenter.tanzu.vmware.com
  fi
}

function configureServiceBindings {
  if isEnabled service-bindings
  then
    banner "Installing Service Bindings"

    installLatest service-bindings service-bindings.labs.vmware.com
  fi
}

function configureScstStore {
  cat > scst-store-values.yaml <<EOF
---
app_service_type: ${STORE_SERVICE_TYPE} # (optional) Defaults to LoadBalancer. Change to NodePort for distributions that don't support LoadBalancer
EOF

  if isEnabled scst-store
  then

    banner "Installing Supply Chain Security Tools - Store"

    installLatest metadata-store \
      scst-store.tanzu.vmware.com \
      scst-store-values.yaml
  fi
}

function configureSigning {
  cat > scst-sign-values.yaml <<EOF
---
allow_unmatched_images: true
EOF

  if isEnabled signing image-policy-webhook
  then
    banner "Installing Supply Chain Security Tools - Sign (Image Policy Webhook)"

    installLatest image-policy-webhook \
      image-policy-webhook.signing.run.tanzu.vmware.com \
      scst-sign-values.yaml
  fi
}

function configureImageSigningPolicy {
  if isEnabled full signing image-policy-webhook
  then
    banner "Creating image-policy-registry-credentials service account and image pull secret"

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
  name: image-policy-registry-credentials
  namespace: image-policy-system
imagePullSecrets:
- name: image-pull-secret
EOF

    banner "Creating basic ClusterImagePolicy"

    cat <<EOF | kubectl apply -f -
apiVersion: signing.apps.tanzu.vmware.com/v1beta1
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
   fi 
}

function configureScanning {

  cat > scst-grype-values.yaml <<EOF
namespace: "default"
targetImagePullSecret: "registry-credentials"
EOF

  if isEnabled scanning grype
  then
    banner "Installing Supply Chain Security Tools - Scan"

    installLatest scan-controller \
      scst-scan.apps.tanzu.vmware.com \
      scst-scan-controller-values.yaml

    banner "Installing Supply Chain Security Tools - Scan (Grype Scanner)"

    installLatest grype-scanner \
      scst-grype.apps.tanzu.vmware.com \
      scst-grype-values.yaml

  fi
}


function configureApiPortal {
  if isEnabled api-portal
  then
    banner "Installing API portal"

    installLatest api-portal api-portal.tanzu.vmware.com
  fi
}

function configureServicesToolkit {
  if isEnabled services-toolkit
  then
    banner "Installing Services Toolkit"

    installLatest services-toolkit services-toolkit.tanzu.vmware.com
  fi
}

function configureTekton {
  if isEnabled tekton
  then
    installLatest tekton tekton.tanzu.vmware.com
  fi
}

function infrastructureProvider {
  if [[ -n "$INFRASTRUCTURE_PROVIDER" ]]
  then
    echo $INFRASTRUCTURE_PROVIDER
    return 0
  fi

  case "$(kubectl version -o json 2> /dev/null | jq -r .serverVersion.gitVersion)" in
  *-gke.*)
    echo "google"
    ;;
  *-eks-*)
    echo "aws"
    ;;
  *)
    if kubectl get ds -n kube-system -o name | grep -q kindnet
    then
      echo "kind"
    elif kubectl get pod -n kube-system -o name | grep -q minikube
    then
      echo "minikube"
    else
      echo "unknown"
    fi
    ;;
  esac
}

function configureContour {
  requireValue CONTOUR_SERVICE_TYPE

  case $(infrastructureProvider) in
  aws)
      cat > contour-values.yaml <<EOF
infrastructure_provider: aws
envoy:
  service:
    aws:
      LBType: classic # classic or nlb (network load balancer)
EOF
      ;;

  google)
    cat > contour-values.yaml <<EOF
envoy:
  service:
    type: LoadBalancer
EOF
    ;;
  kind)
    cat > contour-values.yaml <<EOF
envoy:
  service:
    type: NodePort
    nodePorts: # Matching exposed ports in Kind spec
      http: 31080
      https: 31443
EOF
    ;;
  *)
    cat > contour-values.yaml <<EOF
envoy:
  service:
    type: $CONTOUR_SERVICE_TYPE
EOF
    ;;
  esac

  if isEnabled contour
  then
    banner "Installing Contour"

    installLatest contour contour.tanzu.vmware.com countour-values.yaml
  fi
}

function configureBuiltInProfiles {
  requireValue INSTALL_PROFILE SUPPLY_CHAIN ALV_SERVICE_TYPE

  if isEnabled full light
  then
    cat > tap-values.yaml <<EOF
profile: $INSTALL_PROFILE
ceip_policy_disclosed: true # Installation fails if this is set to 'false'

cnrs:
$(embedYaml cnrs-values.yaml)

contour:
$(embedYaml contour-values.yaml)

buildservice:
$(embedYaml tbs-values.yaml)

appliveview:
  connector_namespaces: [default]
  service_type: "${ALV_SERVICE_TYPE}"

accelerator:
$(embedYaml app-accelerator-values.yaml)

image_policy_webhook:
$(embedYaml scst-sign-values.yaml)

tap_gui:
$(embedYaml tap-gui-values.yaml)

EOF

    case $SUPPLY_CHAIN in
    basic)
      SC_NAME="ootb_supply_chain_basic"
      ;;
    testing)
      SC_NAME="ootb_supply_chain_testing"
      ;;
    scanning|testing_scanning)
      SUPPLY_CHAIN=testing_scanning
      SC_NAME="ootb_supply_chain_testing_scanning"
      ;;
    *)
      fatal "Invalid supply chain for profile install: $SUPPLY_CHAIN"
      ;;
    esac

    cat >> tap-values.yaml <<EOF
supply_chain: ${SUPPLY_CHAIN}

$SC_NAME:
$(embedYaml ootb-supply-chain-values.yaml)

EOF

    if isEnabled full
    then
      cat >> tap-values.yaml <<EOF

learningcenter:
$(embedYaml learning-center-values.yaml)

metadata_store:
$(embedYaml scst-store-values.yaml)

grype:
$(embedYaml scst-grype-values.yaml)

EOF
    fi

    addExclusions

    banner "Installing core TAP profile: $INSTALL_PROFILE"

    installLatest tap tap.tanzu.vmware.com tap-values.yaml 30m
  fi
}

declare -A FULL_PACKAGE
FULL_PACKAGE[accelerator]="accelerator.apps.tanzu.vmware.com"
FULL_PACKAGE[api-portal]="api-portal.tanzu.vmware.com"
FULL_PACKAGE[appliveview]="run.appliveview.tanzu.vmware.com build.appliveview.tanzu.vmware.com"
FULL_PACKAGE[buildservice]="buildservice.tanzu.vmware.com"
FULL_PACKAGE[tbs]="buildservice.tanzu.vmware.com"
FULL_PACKAGE[cartographer]="cartographer.tanzu.vmware.com"
FULL_PACKAGE[cnrs]="cnrs.tanzu.vmware.com"
FULL_PACKAGE[contour]="contour.tanzu.vmware.com"
FULL_PACKAGE[conventions-controller]="controller.conventions.apps.tanzu.vmware.com"
FULL_PACKAGE[convention-controller]="controller.conventions.apps.tanzu.vmware.com"
FULL_PACKAGE[developer-conventions]="developer-conventions.tanzu.vmware.com"
FULL_PACKAGE[grype]="scst-grype.apps.tanzu.vmware.com"
FULL_PACKAGE[image-policy-webhook]="image-policy-webhook.signing.run.tanzu.vmware.com"
FULL_PACKAGE[learningcenter]="learningcenter.tanzu.vmware.com workshops.learningcenter.tanzu.vmware.com"
FULL_PACKAGE[ootb-supply-chain-basic]="ootb-supply-chain-basic.tanzu.vmware.com"
FULL_PACKAGE[ootb-supply-chain-testing]="ootb-supply-chain-testing.tanzu.vmware.com"
FULL_PACKAGE[ootb-supply-chain-testing-scanning]="ootb-supply-chain-testing-scanning.tanzu.vmware.com"
FULL_PACKAGE[ootb-templates]="ootb-templates.tanzu.vmware.com"
FULL_PACKAGE[scst-grype]="scst-grype.tanzu.vmware.com"
FULL_PACKAGE[scst-scan]="scst-scan.tanzu.vmware.com"
FULL_PACKAGE[scst-store]="scst-store.tanzu.vmware.com"
FULL_PACKAGE[signing]="image-policy-webhook.signing.run.tanzu.vmware.com"
FULL_PACKAGE[source-controller]="controller.source.apps.tanzu.vmware.com"
FULL_PACKAGE[spring-boot-conventions]="spring-boot-conventions.tanzu.vmware.com"
FULL_PACKAGE[tap-gui]="tap-gui.tanzu.vmware.com"
FULL_PACKAGE[tekton]="tekton.tanzu.vmware.com"
FULL_PACKAGE[learningcenter-workshops]="workshops.learningcenter.tanzu.vmware.com"

function addExclusions {
  local package
  local fullPackage
  if [[ "$EXCLUDED_PACKAGES" != "none" ]]
  then
    echo "excluded_packages:" >> tap-values.yaml
    for package in $EXCLUDED_PACKAGES
    do
      for fullPackage in ${FULL_PACKAGE[$package]:-$package}
      do
        echo "- $fullPackage" >> tap-values.yaml
      done
    done
  fi
}
function hostIp {
  # This works on both macOS and Linux
  ifconfig -a | awk '/^(en|wl)/,/(inet |status|TX error)/ { if ($1 == "inet") { print $2; exit; } }'
}

function latestPublicTapVersion {
  curl -s https://network.tanzu.vmware.com/api/v2/products/tanzu-application-platform/releases | \
    jq -r '.releases | sort_by(.release_date)[-1].version'
}
