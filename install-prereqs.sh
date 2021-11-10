#!/bin/bash

cat <<EOF
This script will install the pre-requisite tooling for Tanzu Application Platform
on Ubuntu-like systems.

You may be prompted for your password for 'sudo' commands and you will
also need to supply a 'UAA API refresh token' to access files from the Tanzu
Network site. To obtain such a token:

* Go to https://network.tanzu.vmware.com
* Sign in
* Select the drop-down menu that appears when you click on your name
  at the top right-hand corner of the page
* Click on 'Edit Profile'
* At the bottom of the page click on 'Request New Refresh Token'
* Make a copy of the token

EOF
read -p "Hit return to continue: " GO

function log() {
  local line

  echo ""
  for line in "$@"
  do
    echo ">>> $line"
  done
  echo ""
}

function usingWsl() {
  uname -r | grep -qi 'microsoft'
}

if [[ "$(uname -s)/$(uname -m)" != "Linux/x86_64" ]]
then
  log "Sorry, this script only handles Linux x86_64 systems"
  exit 1
fi

log "Installing basic tools"

sudo apt-get update -y
sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  jq

if usingWsl
then
  log "It looks like you are running under WSL" \
    "You must install Docker Desktop if you have not done so already" \
    "This script will install the docker CLI only"

  sudo apt-get install -y docker

else
  log "Removing any existing docker installation"

  sudo apt-get remove -y docker docker-engine docker.io containerd runc

  log "Installing new version of docker"

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
fi

log "Adding $USER to docker group (logout/in to take effect)"
sudo usermod -a -G docker $USER

DOWNLOADS=/tmp/downloads
mkdir -p $DOWNLOADS

log "Installing kubectl"

curl -Lo $DOWNLOADS/kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 $DOWNLOADS/kubectl /usr/local/bin/kubectl

log "Installing kind"

curl -Lo $DOWNLOADS/kind https://kind.sigs.k8s.io/dl/v0.11.1/kind-linux-amd64
sudo install -o root -g root -m 0755 $DOWNLOADS/kind /usr/local/bin/kind

log "Installing carvel tools"

sudo sh -c 'curl -L https://carvel.dev/install.sh | bash'

log "Installing kn"

curl -Lo $DOWNLOADS/kn https://github.com/knative/client/releases/latest/download/kn-linux-amd64
sudo install -o root -g root -m 0755 $DOWNLOADS/kn /usr/local/bin/kn

log "Installing kp"

curl -Lo $DOWNLOADS/kp https://github.com/vmware-tanzu/kpack-cli/releases/download/v0.4.1/kp-linux-0.4.1
sudo install -o root -g root -m 0755 $DOWNLOADS/kp /usr/local/bin/kp

log "Installing pivnet CLI"

curl -Lo $DOWNLOADS/pivnet https://github.com/pivotal-cf/pivnet-cli/releases/download/v3.0.1/pivnet-linux-amd64-3.0.1
sudo install -o root -g root -m 0755 $DOWNLOADS/pivnet /usr/local/bin/pivnet

log "Installing tanzu CLI"

read -p 'Tanzu Network UAA Refresh Token: ' PIVNET_TOKEN
pivnet login --api-token="$PIVNET_TOKEN"
TAP_VERSION=$(pivnet releases -p tanzu-application-platform --format=json | \
  jq -r 'sort_by(.updated_at)[-1].version')

log "Latest TAP release found is $TAP_VERSION"

FILE_ID=$(pivnet product-files \
  -p tanzu-application-platform \
  -r $TAP_VERSION \
  --format=json | jq '.[] | select(.name == "tanzu-framework-bundle-linux").id' )

pivnet download-product-files \
  --download-dir $DOWNLOADS \
  --product-slug='tanzu-application-platform' \
  --release-version=$TAP_VERSION \
  --product-file-id=$FILE_ID

TANZU_DIR=$HOME/tanzu

if [[ -d $TANZU_DIR ]]
then
  UPGRADE_TANZU=true
  tanzu plugin delete imagepullsecret
  tanzu plugin delete package
  tanzu plugin delete accelerator
  tanzu plugin delete apps

  test -d $TANZU_DIR/cli/accelerator/v0.5.0 && \
    test ! -d $TANZU_DIR/cli/accelerator/OLD.v0.5.0 && \
    mv $TANZU_DIR/cli/accelerator/v0.5.0 $TANZU_DIR/cli/accelerator/OLD.v0.5.0
  test -d $TANZU_DIR/cli/apps/v0.5.0 && \
    test ! -d $TANZU_DIR/cli/apps/OLD.v0.5.0 && \
    mv $TANZU_DIR/cli/apps/v0.5.0 $TANZU_DIR/cli/apps/OLD.v0.5.0
else
  UPGRADE_TANZU=false
  mkdir -p $TANZU_DIR
fi

tar xvf $DOWNLOADS/tanzu-framework-linux-amd64.tar -C $TANZU_DIR
MOST_RECENT_CLI=$(find $TANZU_DIR/cli/core/ -name tanzu-core-linux_amd64 | xargs ls -t | head -n 1)
sudo install $MOST_RECENT_CLI /usr/local/bin/tanzu

if $UPGRADE_TANZU
then
  tanzu plugin install secret --local $TANZU_DIR/cli
  tanzu plugin install package --local $TANZU_DIR/cli
  tanzu plugin install accelerator --local $TANZU_DIR/cli
  tanzu plugin install apps --local $TANZU_DIR/cli
  tanzu update --yes --local $TANZU_DIR/cli
else
  tanzu plugin install --local $TANZU_DIR/cli all
fi

tanzu version
tanzu plugin list

log "Done"
