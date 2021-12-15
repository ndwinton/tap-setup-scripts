#!/usr/bin/env bash
set -e
set -o pipefail
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$script_dir/functions.sh"

if [[ -n "$1" ]]
then
  EKS_CLUSTER_NAME=$1
fi

findOrPrompt AWS_REGION "AWS REGION"
findOrPrompt EKS_CLUSTER_NAME "EKS cluster name (the name of the existing cluster)"

eksctl delete cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"

while [[ "$(eksctl get cluster "$EKS_CLUSTER_NAME" 2>&1 || true)" != *"No cluster found"* ]]
do
  message "Waiting for cluster $EKS_CLUSTER_NAME to be nonexistent ..."
  sleep 5
done
