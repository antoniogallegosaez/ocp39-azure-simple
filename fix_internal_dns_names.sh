#!/bin/bash
#This tool fixes the internal dns names that are required for OpenShift Azure cloud provider configuration
#It reads the content of provided parameters.json file and applies the fix based on its content
#Run this script from a host with jq installed and also with AZ cli v2+, login into Azure account and be able to perform az commands

if [ $# -eq 0 ]; then
    echo "Usage: ./fix_internal_dns_names.sh yourazuredeploy.parameters.json yourresourcegroup"
    exit 1
fi

FILE=$1
RESOURCEGROUP=$2

prefix=$(cat "$FILE" | jq -r ".parameters.openshiftClusterPrefix.value")
masters=$(cat "$FILE" | jq -r ".parameters.masterInstanceCount.value")
nodes=$(cat "$FILE" | jq -r ".parameters.nodeInstanceCount.value")
masterloop=$((masters - 1))
nodeloop=$((nodes - 1))


echo "updating masters internal DNS names"
for (( c=0; c<=$masterloop; c++)); do
    az network nic update -g ${RESOURCEGROUP} -n ${prefix}m${c}nic --internal-dns-name ${prefix}m-${c}
    az network nic list | grep ${prefix}m-${c} 
done

echo "updating infranodes internal DNS names"
for (( c=0; c<=$masterloop; c++)); do
    az network nic update -g ${RESOURCEGROUP} -n ${prefix}i${c}nic --internal-dns-name ${prefix}i-${c}
done
echo "checking infranodes changes"
az network nic list | grep ${prefix}i | grep "internalDnsNameLabel"

echo "updating appnodes internal DNS names"
for (( c=0; c<=$masterloop; c++)); do
    az network nic update -g ${RESOURCEGROUP} -n ${prefix}n${c}nic --internal-dns-name ${prefix}n-${c}
done

echo "checking masters changes"
az network nic list | grep ${prefix}m | grep "internalDnsNameLabel"

echo "checking infranodes changes"
az network nic list | grep ${prefix}i | grep "internalDnsNameLabel"

echo "checking nodes changes"
az network nic list | grep ${prefix}n | grep "internalDnsNameLabel"

echo "mission completed"