#!/usr/bin/env bash

cat <<EOF
This script will install the pre-requisite tooling for Tanzu Application Platform
on macOS. It assumes that you are using Homebrew (https://brew.sh) as
the package manager.

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

if [[ "$(uname -s)/$(uname -m)" != "Darwin/x86_64" ]]
then
  log "Sorry, this script only handles macOS x86_64 systems"
  exit 1
fi

log "Installing basic tools"

brew install jq

if which docker > /dev/null
then
  log "Using current Docker installation"
else
  log "You can use either Docker Desktop or docker-machine" \
      "This script will install the docker CLI and docker-machine"
    brew install docker docker-machine
fi

DOWNLOADS=/tmp/downloads
mkdir -p $DOWNLOADS

log "Installing kubectl"

brew install kubectl

log "Installing kind"

brew install kind

log "Installing carvel tools"

brew tap vmware-tanzu/carvel
brew install ytt kbld kapp imgpkg kwt vendir

log "Installing kn"

brew install kn

log "Installing kp"

curl -Lo $DOWNLOADS/kp https://github.com/vmware-tanzu/kpack-cli/releases/download/v0.4.2/kp-darwin-0.4.2
sudo install -m 0755 $DOWNLOADS/kp /usr/local/bin/kp

log "Installing pivnet CLI"

curl -Lo $DOWNLOADS/pivnet https://github.com/pivotal-cf/pivnet-cli/releases/download/v3.0.1/pivnet-darwin-amd64-3.0.1
sudo install -m 0755 $DOWNLOADS/pivnet /usr/local/bin/pivnet

log "Installing tanzu CLI"

read -p 'Tanzu Network UAA Refresh Token: ' PIVNET_TOKEN
pivnet login --api-token="$PIVNET_TOKEN"

ESSENTIALS_VERSION=$(pivnet releases -p tanzu-cluster-essentials --format=json | \
  jq -r 'sort_by(.updated_at)[-1].version')
  
log "Latest Tanzu Cluster Essentials release found is $ESSENTIALS_VERSION"

ESSENTIALS_FILE_NAME=tanzu-cluster-essentials-darwin-amd64-$ESSENTIALS_VERSION.tgz
ESSENTIALS_FILE_ID=$(pivnet product-files \
  -p tanzu-cluster-essentials \
  -r $ESSENTIALS_VERSION \
  --format=json | jq '.[] | select(.name == "'$ESSENTIALS_FILE_NAME'").id' )

pivnet download-product-files \
  --download-dir $DOWNLOADS \
  --product-slug='tanzu-cluster-essentials' \
  --release-version=$ESSENTIALS_VERSION \
  --product-file-id=$ESSENTIALS_FILE_ID

TAP_VERSION=$(pivnet releases -p tanzu-application-platform --format=json | \
  jq -r 'sort_by(.updated_at)[-1].version')

log "Latest TAP release found is $TAP_VERSION"

FILE_ID=$(pivnet product-files \
  -p tanzu-application-platform \
  -r $TAP_VERSION \
  --format=json | jq '.[] | select(.name == "tanzu-framework-bundle-mac").id' )

pivnet download-product-files \
  --download-dir $DOWNLOADS \
  --product-slug='tanzu-application-platform' \
  --release-version=$TAP_VERSION \
  --product-file-id=$FILE_ID

TANZU_DIR=$HOME/tanzu

if [[ -d $TANZU_DIR ]]
then
  UPGRADE_TANZU=true
  tanzu plugin delete imagepullsecret 2> /dev/null
  tanzu plugin delete package 2> /dev/null
  rm -rf $TANZU_DIR/cli/{package,secret,accelerator,services,apps}
  export TANZU_CLI_NO_INIT=true
else
  UPGRADE_TANZU=false
  mkdir -p $TANZU_DIR
fi

tar xvf $DOWNLOADS/tanzu-framework-darwin-amd64.tar -C $TANZU_DIR
MOST_RECENT_CLI=$(find $TANZU_DIR/cli/core/ -name tanzu-core-darwin_amd64 | xargs ls -t | head -n 1)
sudo install -m 0755 $MOST_RECENT_CLI /usr/local/bin/tanzu

tanzu config set features.global.context-aware-cli-for-plugins false

if $UPGRADE_TANZU
then
  tanzu update --yes --local $TANZU_DIR/cli
  tanzu plugin install secret --local $TANZU_DIR/cli
  tanzu plugin install package --local $TANZU_DIR/cli
  tanzu plugin install accelerator --local $TANZU_DIR/cli
  tanzu plugin install apps --local $TANZU_DIR/cli
  tanzu plugin install services --local $TANZU_DIR/cli
else
  tanzu plugin install --local $TANZU_DIR/cli all
fi

tanzu version
tanzu plugin list

log "Done"
