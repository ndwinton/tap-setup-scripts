#!/bin/bash

set -e

cat <<EOT
This script will set up Tanzu Application Platform (Beta 1) on a machine
with the necessary tooling (Carvel tools, kpack and knative clients)
already installed, along with a Kubernetes cluster.

You will need an account on the Tanzu Network (aka PivNet) and an account
for a Docker registry, such as DockerHub or Harbor.

EOT
read -p "Tanzu Network Username: " TN_USERNAME
read -sp "Tanzu Network Password: " TN_PASSWORD

cat <<EOT

The Docker registry should be something like 'myuser/tap' for DockerHub or
'harbor-repo.example.com/myuser/tap' for an internal registry.
 
EOT
read -p "Docker Registry: " REGISTRY
read -p "Registry Username: " REG_USERNAME
read -sp "Registry Password: " REG_PASSWORD

REG_HOST=${REGISTRY%%/*}
if [[ $REG_HOST != *.* ]]
then
  # Using DockerHub
  REG_HOST=''
fi

echo ">>> Deploying kapp controller ..."
kapp deploy -a kc -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/latest/download/release.yml -y

echo ">>> Creating tap-install namespace ..."
(kubectl get ns tap-install 2> /dev/null) || \
  kubectl create ns tap-install
(kubectl get secret -n tap-install tap-registry 2> /dev/null) || \
  kubectl create secret docker-registry tap-registry \
    -n tap-install \
    --docker-server='registry.pivotal.io' \
    --docker-username="$TN_USERNAME" \
    --docker-password="$TN_PASSWORD"

echo ">>> Creating TAP package repository ..."
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

echo ">>> Deploying Cloud Native Runtime ..."
cat > cnr-values.yaml <<EOF
---
registry:
 server: "registry.pivotal.io"
 username: "$TN_USERNAME"
 password: "$TN_PASSWORD"

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

echo ">>> Setting CNR (knative) domain to vcap.me ..."

cat > vcap-me.yaml <<EOF
apiVersion: v1
data:
  vcap.me: |
kind: ConfigMap
metadata:
  name: config-domain
  namespace: knative-serving
EOF

kubectl apply -f vcap-me.yaml

echo ">>> Deploying Flux ..."
kapp deploy -a flux -f https://github.com/fluxcd/flux2/releases/download/v0.15.0/install.yaml -y

# Remove flux networkpolicies (known to cause problems with Traefik)
kubectl delete networkpolicy allow-egress -n flux-system
kubectl delete networkpolicy allow-scraping -n flux-system
kubectl delete networkpolicy allow-webhooks -n flux-system

echo ">>> Deploying App Accelerator ..."
cat > app-accelerator-values.yaml <<EOF
---
registry:
  server: "registry.pivotal.io"
  username: "$TN_USERNAME"
  password: "$TN_PASSWORD"
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
#kubectl get all -n accelerator-system
#kubectl -n accelerator-system describe service acc-ui-server

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

echo ">>> Installing App Live View ..."
cat > app-live-view-values.yaml <<EOF
---
registry:
  server: "registry.pivotal.io"
  username: "$TN_USERNAME"
  password: "$TN_PASSWORD"
EOF

tanzu package install app-live-view -p appliveview.tanzu.vmware.com -v 0.1.0 -n tap-install -f app-live-view-values.yaml --poll-timeout 10m
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
