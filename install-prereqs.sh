#/bin/bash

cat <<EOF
This script will install the pre-requisite tooling for Tanzu Application Platform

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
  echo ""
  echo ">>> $*"
  echo ""
}

log "Removing any existing docker installation"

sudo apt-get remove -y docker docker-engine docker.io containerd runc

log "Installing basic tools"

sudo apt-get update -y
sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  jq

log "Installing new version of docker"

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

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

curl -Lo $DOWNLOADS/kn https://github.com/knative/client/releases/download/v0.26.0/kn-darwin-amd64
sudo install -o root -g root -m 0755 $DOWNLOADS/kn /usr/local/bin/kn

log "Installing kp"

curl -Lo $DOWNLOADS/kp https://github.com/vmware-tanzu/kpack-cli/releases/download/v0.3.1/kp-linux-0.3.1
sudo install -o root -g root -m 0755 $DOWNLOADS/kp /usr/local/bin/kp

log "Installing pivnet CLI"

curl -Lo $DOWNLOADS/pivnet https://github.com/pivotal-cf/pivnet-cli/releases/download/v3.0.1/pivnet-linux-amd64-3.0.1
sudo install -o root -g root -m 0755 $DOWNLOADS/pivnet /usr/local/bin/pivnet

log "Installing tanzu CLI"

read -p 'Tanzu Network UAA Refresh Token: ' PIVNET_TOKEN
pivnet login --api-token="$PIVNET_TOKEN"
pivnet download-product-files --download-dir $DOWNLOADS --product-slug='tanzu-application-platform' --release-version='0.2.0' --product-file-id=1055586
TANZU_DIR=$HOME/tanzu
mkdir -p $TANZU_DIR
rm -rf $TANZU_DIR/*
tar xvf $DOWNLOADS/tanzu-framework-linux-amd64.tar -C $TANZU_DIR
sudo install $TANZU_DIR/cli/core/v0.5.0/tanzu-core-linux_amd64 /usr/local/bin/tanzu
export TANZU_CLI_NO_INIT=true
tanzu plugin repo update -b tanzu-cli-framework core
tanzu plugin clean
tanzu plugin install --local $TANZU_DIR/cli all
tanzu plugin list

log "Done"
