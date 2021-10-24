#!/bin/bash
#
#  This script troubleshoots errors related to onboarding of Azure Monitor for containers to Kubernetes cluster hosted outside and connected to Azure via Azure Arc cluster
# Prerequisites :
#     Azure CLI:  https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest

# bash troubelshooterror.sh --resource-id <clusterResourceId> --kube-context <kube-context> --cloudName

set -e
set -o pipefail

logFile="TroubleshootDump.log"
clusterType="connectedClusters"
extensionInstanceName="azuremonitor-containers"
# resource type for azure log analytics workspace
workspaceResourceProvider="Microsoft.OperationalInsights/workspaces"
workspaceSolutionResourceProvider="Microsoft.OperationsManagement/solutions"
contactUSMessage="Please contact us by emailing askcoin@microsoft.com if you need any help with this script captured logs"
dataCapHelpMessage="Please review and increase data cap https://docs.microsoft.com/en-us/azure/azure-monitor/logs/manage-cost-storage"
workspacePrivateLinkMessage="Please review this doc https://docs.microsoft.com/en-us/azure/azure-monitor/logs/private-link-security"
azureCLIInstallLinkMessage="Please install Azure-CLI as per the instructions https://docs.microsoft.com/en-us/cli/azure/install-azure-cli and rerun the troubleshooting script"
kubectlInstallLinkMessage="Please install kubectl as per the instructions https://kubernetes.io/docs/tasks/tools/#kubectl and rerun the troubleshooting script"
jqInstallLinkMessage="Please install jq as per instructions https://stedolan.github.io/jq/download/ and rerun the troubleshooting script"

log_message() {
  echo "$@"
  echo ""
  echo "$@" >> $logFile
}


login_to_azure() {
  if [ "$isUsingServicePrincipal" = true ]; then
    log_message "login to the azure using provided service principal creds"
    az login --service-principal --username="$servicePrincipalClientId" --password="$servicePrincipalClientSecret" --tenant="$servicePrincipalTenantId"
  else
    log_message "login to the azure interactively"
    az login --use-device-code
  fi
}

set_azure_subscription() {
  local subscriptionId="$(echo ${1})"
  log_message "setting the subscription id: ${subscriptionId} as current subscription for the azure cli"
  az account set -s ${subscriptionId}
  log_message "successfully configured subscription id: ${subscriptionId} as current subscription for the azure cli"
}

usage() {
  local basename=$(basename $0)
  echo
  echo "Troubleshooting Errors related to Azure Monitor for containers:"
  echo "$basename --resource-id <cluster resource id> [--kube-context <name of the kube context >]"
}

parse_args() {

  if [ $# -le 1 ]; then
    usage
    exit 1
  fi

  # Transform long options to short ones
  for arg in "$@"; do
    shift
    case "$arg" in
    "--resource-id") set -- "$@" "-r" ;;
    "--kube-context") set -- "$@" "-k" ;;
    "--"*) usage ;;
    *) set -- "$@" "$arg" ;;
    esac
  done

  local OPTIND opt

  while getopts 'hk:r:' opt; do
    case "$opt" in
    h)
      usage
      ;;

    k)
      kubeconfigContext="$OPTARG"
      log_message "name of kube-context is $OPTARG"
      ;;

    r)
      clusterResourceId="$OPTARG"
      log_message "clusterResourceId is $OPTARG"
      ;;

    ?)
      usage
      exit 1
      ;;
    esac
  done
  shift "$(($OPTIND - 1))"

  local subscriptionId="$(echo ${clusterResourceId} | cut -d'/' -f3)"
  local resourceGroup="$(echo ${clusterResourceId} | cut -d'/' -f5)"

  # get resource parts and join back to get the provider name
  local providerNameResourcePart1="$(echo ${clusterResourceId} | cut -d'/' -f7)"
  local providerNameResourcePart2="$(echo ${clusterResourceId} | cut -d'/' -f8)"
  local providerName="$(echo ${providerNameResourcePart1}/${providerNameResourcePart2})"

  local clusterName="$(echo ${clusterResourceId} | cut -d'/' -f9)"

  # convert to lowercase for validation
  providerName=$(echo $providerName | tr "[:upper:]" "[:lower:]")

  log_message "cluster SubscriptionId:" $subscriptionId
  log_message "cluster ResourceGroup:" $resourceGroup
  log_message "cluster ProviderName:" $providerName
  log_message "cluster Name:" $clusterName

  if [ -z "$subscriptionId" -o -z "$resourceGroup" -o -z "$providerName" -o -z "$clusterName" ]; then
    log_message "-e invalid cluster resource id. Please try with valid fully qualified resource id of the cluster"
    exit 1
  fi

  if [[ $providerName != microsoft.* ]]; then
    log_message "-e invalid azure cluster resource id format."
    exit 1
  fi

  # detect the resource provider from the provider name in the cluster resource id
  if [ $providerName = "microsoft.kubernetes/connectedclusters" ]; then
    log_message "provider cluster resource is of Azure Arc enabled Kubernetes cluster type"
    isArcK8sCluster=true
    resourceProvider=$arcK8sResourceProvider
  else
    log_message "-e not valid azure arc enabled kubernetes cluster resource id"
    exit 1
  fi

  if [ -z "$kubeconfigContext" ]; then
    log_message "using or getting current kube config context since --kube-context parameter not set "
  fi

  if [ ! -z "$servicePrincipalClientId" -a ! -z "$servicePrincipalClientSecret" -a ! -z "$servicePrincipalTenantId" ]; then
    log_message "using service principal creds (clientId, secret and tenantId) for azure login since provided"
    isUsingServicePrincipal=true
  fi
}

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

validate_ci_extension() {
  extension=$(az k8s-extension show -c ${4} -g ${3} -t $clusterType -n $extensionInstanceName)
  log_message $extension
  configurationSettings=$(az k8s-extension show -c ${4} -g ${3} -t $clusterType -n $extensionInstanceName --query "configurationSettings.logAnalyticsWorkspaceResourceID")
  if [ -z "$configurationSettings" ]; then
     log_message "-e error configurationSettings either null or empty"
     log_message ${contactUSMessage}
     exit 1
  fi
  logAnalyticsWorkspaceResourceID=$(az k8s-extension show -c ${4} -g ${3} -t $clusterType -n $extensionInstanceName --query "configurationSettings.logAnalyticsWorkspaceResourceID")
  if [ -z "$logAnalyticsWorkspaceResourceID" ]; then
     log_message "-e error logAnalyticsWorkspaceResourceID either null or empty in the config settings"
     log_message ${contactUSMessage}
     exit 1
  fi

  provisioningState=$(az k8s-extension show -c ${4} -g ${3} -t $clusterType -n $extensionInstanceName  --query "provisioningState")
  if [ -z "$provisioningState" ]; then
     log_message "-e error provisioningState either null or empty in the config settings"
     log_message ${contactUSMessage}
     exit 1
  fi
  if [ $provisioningState = "Succeeded" ]; then
     log_message "-e error expected state of extension provisioningState MUST be Succeeded state but actual state is ${provisioningState}"     
     log_message ${contactUSMessage}
     exit 1
  fi
  logAnalyticsWorkspaceDomain=$(az k8s-extension show -c ${4} -g ${3} -t $clusterType -n $extensionInstanceName --query 'configurationSettings."omsagent.domain"')
  if [ -z "$logAnalyticsWorkspaceDomain" ]; then
     log_message "-e error logAnalyticsWorkspaceDomain either null or empty in the config settings"
     log_message ${contactUSMessage}
     exit 1
  fi
  azureCloudName=${1}
  if [ "$azureCloudName" = "azureusgovernment" ]; then
     if [ $logAnalyticsWorkspaceDomain = "opinsights.azure.us" ]; then
        log_message "-e error expected value of logAnalyticsWorkspaceDomain  MUST opinsights.azure.us but actual value is ${logAnalyticsWorkspaceDomain}"
        log_message ${contactUSMessage}
        exit 1
     fi
  elif [ "$azureCloudName" = "azurecloud" ]; then
    if [ $logAnalyticsWorkspaceDomain = "opinsights.azure.com" ]; then
      log_message "-e error expected value of logAnalyticsWorkspaceDomain  MUST opinsights.azure.com but actual value is ${logAnalyticsWorkspaceDomain}"
      log_message ${contactUSMessage}
      exit 1
    fi
  elif [ "$azureCloudName" = "azurechinacloud" ]; then
    if [ $logAnalyticsWorkspaceDomain = "opinsights.azure.cn" ]; then
      log_message "-e error expected value of logAnalyticsWorkspaceDomain  MUST opinsights.azure.cn but actual value is ${logAnalyticsWorkspaceDomain}"
      log_message ${contactUSMessage}
      exit 1
    fi
  fi

  workspaceSubscriptionId="$(echo ${logAnalyticsWorkspaceResourceID} | cut -d'/' -f3 | tr "[:upper:]" "[:lower:]")"
  workspaceResourceGroup="$(echo ${logAnalyticsWorkspaceResourceID} | cut -d'/' -f5)"
  workspaceName="$(echo ${logAnalyticsWorkspaceResourceID} | cut -d'/' -f9)"

  clusterSubscriptionId=${2}
  # set the azure subscription to azure cli if the workspace in different sub than cluster
  if [[ "$clusterSubscriptionId" != "$workspaceSubscriptionId" ]]; then
    log_message "switch subscription id of workspace as active subscription for azure cli since workspace in different subscription than cluster: ${workspaceSubscriptionId}"
    isClusterAndWorkspaceInSameSubscription=false
    set_azure_subscription $workspaceSubscriptionId
  fi
  workspaceList=$(az resource list -g $workspaceResourceGroup -n $workspaceName --resource-type $workspaceResourceProvider)
  if [ "$workspaceList" = "[]" ]; then
     log_message "-e error workspace:${logAnalyticsWorkspaceResourceID} doesnt exist"
     exit 1
  fi

  ciSolutionResourceId="/subscriptions/${workspaceSubscriptionId}/resourceGroups/${workspaceResourceGroup}/Microsoft.OperationsManagement/solutions/ContainerInsights(${workspaceName})"
  ciSolutionResourceName=$(az resource show --ids "$ciSolutionResourceId"  --query name)
  if [[ "$ciSolutionResourceName" != "ContainerInsights(${workspaceName})" ]]; then
     log_message "-e error ContainerInsights solution on workspace ${logAnalyticsWorkspaceResourceID} doesnt exist"
     log_message ${contactUSMessage}
     exit 1
  fi

  publicNetworkAccessForIngestion=$(az resource show --ids ${logAnalyticsWorkspaceResourceID} --query properties.publicNetworkAccessForIngestion)
  log_message "workspace publicNetworkAccessForIngestion: ${publicNetworkAccessForIngestion}"
  if [[ "$publicNetworkAccessForIngestion" != "Enabled" ]]; then
     log_message "-e error Unless private link configured, publicNetworkAccessForIngestion MUST be enabled for data ingestion"
     log_message ${workspacePrivateLinkMessage}
     exit 1
  fi
  publicNetworkAccessForQuery=$(az resource show --ids ${logAnalyticsWorkspaceResourceID} --query properties.publicNetworkAccessForQuery)
  log_message "workspace publicNetworkAccessForQuery: ${publicNetworkAccessForQuery}"
  if [[ "$publicNetworkAccessForIngestion" != "Enabled" ]]; then
    log_message "-e error Unless private link configured, publicNetworkAccessForQuery MUST be enabled for data query"
    log_message ${workspacePrivateLinkMessage}
    exit 1
  fi

  workspaceCappingDailyQuotaGb=$(az resource show --ids ${logAnalyticsWorkspaceResourceID} --query properties.workspaceCapping.dailyQuotaGb)
  log_message "workspaceCapping dailyQuotaGb: ${workspaceCappingDailyQuotaGb}"
  if [[ "$workspaceCappingDailyQuotaGb" != "1.0" ]]; then
    log_message "-e error workspace configured daily quota and verify ingestion data reaching over the quota: ${workspaceCappingDailyQuotaGb}"
    log_message ${dataCapHelpMessage}
    exit 1
  fi
}

validate_ci_agent_pods() { 

}

if command_exists az; then
   log_message "detected azure cli installed"
   azCLIVersion=$(az -v)
   log_message "azure-cli version: ${azCLIVersion}"
   azCLIExtension=$(az extension list --query "[?name=='k8s-extension'].name | [0]")
   if [ $azCLIExtension = "k8s-extension" ]; then
      azCLIExtensionVersion=$(az extension list --query "[?name=='k8s-extension'].version | [0]")
      log_message "detected k8s-extension and current installed version: ${azCLIExtensionVersion}"
      az extension update --name 'k8s-extension'
   else
     log_message "adding k8s-extension since k8s-extension doesnt exist as installed"
     az extension add --name 'k8s-extension'
   fi
   azCLIExtensionVersion=$(az extension list --query "[?name=='k8s-extension'].version | [0]")
   log_message "current installed k8s-extension version: ${azCLIExtensionVersion}"
else
  log_message "-e error azure cli doesnt exist as installed"
  log_message ${azureCLIInstallLinkMessage}  
  exit 1
fi

# parse and validate args
parse_args $@

# parse cluster resource id
clusterSubscriptionId="$(echo $clusterResourceId | cut -d'/' -f3 | tr "[:upper:]" "[:lower:]")"
clusterResourceGroup="$(echo $clusterResourceId | cut -d'/' -f5)"
providerName="$(echo $clusterResourceId | cut -d'/' -f7)"
clusterName="$(echo $clusterResourceId | cut -d'/' -f9)"

azureCloudName=$(az cloud show --query name -o tsv | tr "[:upper:]" "[:lower:]" | tr -d "[:space:]")
log_message "azure cloud name: ${azureCloudName}"

# login to azure interactively
login_to_azure

# set the cluster subscription id as active sub for azure cli
set_azure_subscription $clusterSubscriptionId

# validate ci extension
validate_ci_extension $azureCloudName $clusterSubscriptionId $clusterResourceGroup $clusterName

# validate ci agent pods
if command_exists kubectl; then
   if command_exists jq; then 
     log_message "-e error jq doesnt exist as installed"
     log_message $jqInstallLinkMessage
     exit 1
   fi
   validate_ci_agent_pods 
else 
  log_message "-e error kubectl doesnt exist as installed"
  log_message ${kubectlInstallLinkMessage}
  exit 1
fi

log_message "Everything looks good according to this script."
log_message $contactUSMessage
