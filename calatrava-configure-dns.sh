#!/usr/bin/env bash
source "$(dirname $0)/functions.sh"

set -e

function enableExternalDns {
  banner "Enabling External DNS"

  kubectl apply -f \
    https://raw.githubusercontent.com/kubernetes-sigs/external-dns/v0.7.1/docs/contributing/crd-source/crd-manifest.yaml
}

function createDnsRecord {
  local fqdn="$1"
  local service="$2"
  local namespace="$3"

  banner "Creating DNS record for $fqdn"
  
  local ip=$(kubectl get -n $namespace service $service -o jsonpath='{$.status.loadBalancer.ingress[0].ip}')

  if [[ "$ip" == "" ]]
  then
    message "Can't find IP address for service '$service' in namespace '$namespace'"
    return
  fi

  kubectl apply -f- <<EOF
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: $service-$namespace
spec:
  endpoints:
  - dnsName: $fqdn
    recordTTL: 180
    recordType: A
    targets:
    - $ip
EOF

}

cat << EOF
This script sets up DNS for TAP installations within the calatrava.vmware.com domain.

DNS for the main system ingress (via Contour/Envoy) should have been taken
care of via annotations added during that package installation. This script
only deals with the remaining DNS entries not handled in that manner.

EOF

findOrPrompt DOMAIN "Root Domain"
findOrPromptWithDefault GUI_DOMAIN "UI Domain" "gui.${DOMAIN}"

if [[ "$DOMAIN" != *.calatrava.vmware.com ]] || [[ "$GUI_DOMAIN" != *.calatrava.vmware.com ]]
then
  message "This script can only be used to set up DNS within the calatrava.vmware.com domain"
  exit 1
fi

enableExternalDns

createDnsRecord "$GUI_DOMAIN" server tap-gui

