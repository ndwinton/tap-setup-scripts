#!/usr/bin/env bash
set -o errexit # set -e
set -o pipefail

## FROM: https://www.youtube.com/watch?v=p6xDCz00TxU, the pertinent stuff starting at approx. 6:26

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

findOrPrompt AWS_REGION "AWS region"
findOrPrompt EKS_CLUSTER_NAME "EKS cluster name (choose a name)"

set -x

k8s_version=1.21
instance_type=t2.xlarge # 4 CPUs, 16G RAM, 80G storage per node. I think this is among the smallest types that will support EKS.
node_count=3 # 1 is too few, 3 works. Not tried 2.

eksctl create cluster \
  --name "$EKS_CLUSTER_NAME" \
  --version "$k8s_version" \
  --region "$AWS_REGION" \
  --nodegroup-name worker-nodes \
  --node-type "$instance_type" \
  --nodes "$node_count"
