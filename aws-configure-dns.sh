#!/usr/bin/env bash
source "$(dirname $0)/functions.sh"

set -e
set -x
findOrPrompt DOMAIN "Root Domain"
cat << EOF

>>> NOTE: The following domains should be subdomains of $DOMAIN.

EOF
findOrPromptWithDefault GUI_DOMAIN "UI Domain" "gui.${DOMAIN}"
findOrPromptWithDefault APPS_DOMAIN "Applications root domain" "apps.${DOMAIN}"
findOrPromptWithDefault EDUCATES_DOMAIN "Learning Center domain" "learn.${DOMAIN}"

function createDnsRecord {
  fqdn=$1
  resource_type=$2
  resource_name=$3
  namespace=$4

  elb_hostname=$(kubectl get "$resource_type/$resource_name" -n "$namespace" -o json 2>/dev/null| jq '.status.loadBalancer.ingress[0].hostname'|sed 's/\"//g')
  if [[ "$elb_hostname" == "" || "$elb_hostname" == "null" ]]
  then
    echo "Will not create DNS entry for $fqdn"
    return
  fi

  echo "Creating DNS entry for $fqdn, hostname=$elb_hostname"

  elb_zone_id=$(aws elb describe-load-balancers| jq --arg DNSNAME "${elb_hostname}" '.LoadBalancerDescriptions[] | select( .DNSName == $DNSNAME ) | .CanonicalHostedZoneNameID ' | sed s/\"//g)
  file="$fqdn.json"
  cat > "$file" << EOF
{
    "Comment": "Creating $fqdn Alias resource record sets in Route 53",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$fqdn",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "$elb_zone_id",
                    "DNSName": "dualstack.$elb_hostname",
                    "EvaluateTargetHealth": false
                }
            }
        }
    ]
}
EOF
  aws route53 change-resource-record-sets --hosted-zone-id ${zone_id}  --change-batch "file://$file"
}

zone_id=$(aws route53 list-hosted-zones|jq --arg DOMAIN "${DOMAIN}." '.HostedZones[] | select( .Name == $DOMAIN ) | .Id'| sed 's/\/hostedzone\///g'|sed 's/\"//g')
if [[ $? -ne 0 || "$zone_id" == "" ]]
then
  echo "Unable to extract host zone ID. Exiting."
  exit 1
fi

createDnsRecord "*.$APPS_DOMAIN" service envoy tanzu-system-ingress

createDnsRecord "*.$EDUCATES_DOMAIN" ingress learningcenter-portal learning-center-guided-ui

createDnsRecord "$GUI_DOMAIN" service server tap-gui

kubectl patch cm/config-domain -n knative-serving -p "{ \"data\": null }"
kubectl patch cm/config-domain -n knative-serving -p "{ \"data\": { \"$APPS_DOMAIN\": \"\" } }"
