#!/bin/bash
##########################################################################################################################################################################################
#- Purpose: Script used to install pre-requisites, deploy/undeploy service, start/stop service, test service
#- Parameters are:
#- [-a] action - value: login, install, deploy, undeploy, start, stop, status, test
#- [-e] Stop on Error - by default false
#- [-s] Silent mode - by default false
#- [-c] configuration file - which contains the list of path of each avtool.sh to call (avtool.env by default)
#- [-d] deployment file relative path - by default ./deployment.rtmp.amd64.json used for the test only
#- [-o] operation file relative path - by default ./operations.template.json
#- [-v] video url - http url or local relative path (../../../../content/camera-300s.mkv) or live if external source, by default https://avamedia.blob.core.windows.net/public/camera-300s.mkv 
#- [-n] video name - name of the recording by default sample-motion-video-camera001
#
# executable
###########################################################################################################################################################################################
set -u
repoRoot="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$repoRoot"
#######################################################
#- function used to print out script usage
#######################################################
function usage() {
    printMessage ""
    printMessage "Arguments:"
    printMessage " -a  Sets AV Tool action {install, deploy, undeploy, start, stop, status, test}"
    printMessage " -c  Sets the AV Tool configuration file"
    printMessage " -e  Sets the stop on error (false by defaut)"
    printMessage " -s  Sets Silent mode installation or deployment (false by defaut)"
    printMessage " -d  Sets deployment file path used for test action only by default: ./deployment.rtmp.amd64.json"
    printMessage " -o  Sets operation file path used for test action only by default: ./operations.template.json"
    printMessage " -v  Sets video file path or uri  used for test action only by default https://avamedia.blob.core.windows.net/public/camera-300s.mkv"
    printMessage " -n  Sets video name for the recording used for test action only by default sample-motion-video-camera001"
    printMessage ""
    printMessage "Example:"
    printMessage " bash ./avtool.sh -a install "
    printMessage " bash ./avtool.sh -a start -c avtool.env -e true -s true"
    printMessage " bash ./avtool.sh -a test -d ./deployment.tracking.json -o ./operations.tracking.template.json -v https://avamedia.blob.core.windows.net/public/camera-300s.mkv -n camera001"
    
}
action=
configuration_file=.avtoolconfig
stoperror=false
silentmode=false
deployment=""
operation=""
video=""
videoname=""
while getopts "a:c:e:s:d:o:v:n:hq" opt; do
    case $opt in
    a) action=$OPTARG ;;
    c) configuration_file=$OPTARG ;;
    e) stoperror=$OPTARG ;;
    s) silentmode=$OPTARG ;;
    d) deployment=$OPTARG ;;
    o) operation=$OPTARG ;;
    v) video=$OPTARG ;;
    n) videoname=$OPTARG ;;
    :)
        printError "Error: -${OPTARG} requires a value"
        exit 1
        ;;
    *)
        usage
        exit 1
        ;;
    esac
done

# Validation
if [[ $# -eq 0 || -z $action || -z $configuration_file ]]; then
    printError "Required parameters are missing"
    usage
    exit 1
fi
if [[ ! $action == login && ! $action == install && ! $action == start && ! $action == stop && ! $action == status && ! $action == deploy && ! $action == undeploy && ! $action == test && ! $action == integration ]]; then
    printError "Required action is missing, values: login, install, deploy, undeploy, start, stop, status, test, integration"
    usage
    exit 1
fi
##############################################################################
# colors for formatting the ouput
##############################################################################
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color
##############################################################################
#- print functions
##############################################################################
function printMessage(){
    echo -e "${GREEN}$1${NC}" 
}
function printWarning(){
    echo -e "${YELLOW}$1${NC}" 
}
function printError(){
    echo -e "${RED}$1${NC}" 
}
function printProgress(){
    echo -e "${BLUE}$1${NC}" 
}
##############################################################################
#- function used to check whether an error occured
##############################################################################
checkError() {
    if [ $? -ne 0 ]; then
        printError "An error occured exiting from the current bash"
        exit 1
    fi
}
checkLoginAndSubscription() {
    az account show -o none
    if [ $? -ne 0 ]; then
        printError "\nYou seems disconnected from Azure, running 'az login'."
        az login -o none
    fi
    CURRENT_SUBSCRIPTION_ID=$(az account show --query 'id' --output tsv)
    if [[ -z "$AV_SUBSCRIPTION_ID"  || "$AV_SUBSCRIPTION_ID" != "$CURRENT_SUBSCRIPTION_ID" ]]; then
        # query subscriptions
        printMessage "\nYou have access to the following subscriptions:"
        az account list --query '[].{name:name,"subscription Id":id}' --output table

        printMessage "\nYour current subscription is:"
        az account show --query '[name,id]'
        if [[ ${silentmode} == false || -z "$CURRENT_SUBSCRIPTION_ID" ]]; then        
            printMessage "
            You will need to use a subscription with permissions for creating service principals (owner role provides this).
            If you want to change to a different subscription, enter the name or id.
            Or just press enter to continue with the current subscription."
            read -p ">> " SUBSCRIPTION_ID

            if ! test -z "$SUBSCRIPTION_ID"
            then 
                az account set -s "$SUBSCRIPTION_ID"
                printMessage "\nNow using:"
                az account show --query '[name,id]'
                CURRENT_SUBSCRIPTION_ID=$(az account show --query 'id' --output tsv)
            fi
        fi
        AV_SUBSCRIPTION_ID=$CURRENT_SUBSCRIPTION_ID
        sed -i "/AV_SUBSCRIPTION_ID=/d" "$repoRoot"/"$configuration_file"; echo "AV_SUBSCRIPTION_ID=$AV_SUBSCRIPTION_ID" >> "$repoRoot"/"$configuration_file" 
    fi
}
getPublicIPAddress() {
    getPublicIPAddressResult=$(dig +short myip.opendns.com @resolver1.opendns.com)
}
checkOutputFiles () {
    checkOutputFilesResult="1"
    prefix="$1"
    for i in 0 1 
    do
        printProgress "checking file: ${AV_TEMPDIR}/${prefix}${i}.mp4 size: $(wc -c ${AV_TEMPDIR}/${prefix}${i}.mp4 | awk '{print $1}')"
        if [[ ! -f "${AV_TEMPDIR}"/${prefix}${i}.mp4 || $(wc -c "${AV_TEMPDIR}"/${prefix}${i}.mp4 | awk '{print $1}') < 10000 ]]; then 
            checkOutputFilesResult="0"
            return
        fi
    done 
    return
}
setContainerState () {
    state="$1"
    #az vm stop -n ${AV_VMNAME} -g ${AV_RESOURCE_GROUP} 
    #az vm deallocate -n ${AV_VMNAME} -g ${AV_RESOURCE_GROUP}
    #az vm start -n ${AV_VMNAME} -g ${AV_RESOURCE_GROUP} 
    #az iot hub invoke-module-method --method-name 'RestartModule' -n ${AV_IOTHUB}  -d ${AV_EDGE_DEVICE} -m '$edgeAgent' --method-payload '{"schemaVersion": "1.0","id": "rtmpsource"}'
    sed "s/{AV_STATE}/$state/g" < ${AV_TEST_DEPLOYMENT} >  ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_CONTAINER_REGISTRY}/$AV_CONTAINER_REGISTRY/" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_CONTAINER_REGISTRY_USERNAME}/$AV_CONTAINER_REGISTRY_USERNAME/" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_CONTAINER_REGISTRY_PASSWORD}/${AV_CONTAINER_REGISTRY_PASSWORD//\//\\/}/" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_CONTAINER_REGISTRY_DNS_NAME}/${AV_CONTAINER_REGISTRY_DNS_NAME//\//\\/}/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_IMAGE_NAME}/${AV_IMAGE_NAME}/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_IMAGE_FOLDER}/${AV_IMAGE_FOLDER}/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_PORT_RTMP}/$AV_PORT_RTMP/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_PORT_RTSP}/$AV_PORT_RTSP/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_PORT_HTTP}/$AV_PORT_HTTP/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_PORT_HLS}/$AV_PORT_HLS/g" ${AV_TEMPDIR}/deployment.template.json    
    sed -i "s/{AV_PORT_SSL}/$AV_PORT_SSL/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_COMPANYNAME}/$AV_COMPANYNAME/g" ${AV_TEMPDIR}/deployment.template.json    
    sed -i "s/{AV_HOSTNAME}/$AV_HOSTNAME/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_VIDEO_OUTPUT_FOLDER_ON_DEVICE}/\/var\/media/" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_APPDATA_FOLDER_ON_DEVICE}/\/var\/lib\/azuremediaservices/" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_SUBSCRIPTION_ID}/${AV_SUBSCRIPTION_ID//\//\\/}/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_RESOURCE_GROUP}/$AV_RESOURCE_GROUP/g" ${AV_TEMPDIR}/deployment.template.json
    sed -i "s/{AV_AVA_PROVISIONING_TOKEN}/${AV_AVA_PROVISIONING_TOKEN//\//\\/}/g" ${AV_TEMPDIR}/deployment.template.json
    az iot edge set-modules --device-id ${AV_EDGE_DEVICE} --hub-name ${AV_IOTHUB} --content ${AV_TEMPDIR}/deployment.template.json > /dev/null
    checkError
}
getContainerState () {
    getContainerStateResult="unknown"
    getContainerStateResult=$(az iot hub query -n ${AV_IOTHUB} -q "select * from devices.modules where devices.deviceId = '${AV_EDGE_DEVICE}' and devices.moduleId = '\$edgeAgent' " --query '[].properties.reported.modules.rtmpsource.status'  --output tsv)
    checkError
    if [[ $getContainerStateResult == "" || -z $getContainerStateResult ]]; then
        getContainerStateResult="unknown"
    fi
    return
}
stopContainer() {
    setContainerState "stopped"
    printProgress "Stop command sent"
    x=1
    while : ; do 
        if [ $x -gt 12 ] ; then
            printError "An error occured exiting from the current bash: Timeout while stopping the container"
            exit 1
        fi 
        getContainerState 
        if [[ $getContainerStateResult == "stopped" || $getContainerStateResult == "unknown" ]]; then echo "Container is stopped"; break; fi; 
        printProgress "Waiting for container in stopped state, currently it is $getContainerStateResult"; 
        sleep 10; 
        x=$(( $x + 1 ))
    done; 
}
startContainer() {
    setContainerState "running"
    printProgress "Start command sent"
    x=1
    while : ; do
        if [ $x -gt 12 ] ; then
            printError "An error occured exiting from the current bash: Timeout while starting the container"
            exit 1
        fi 
        getContainerState 
        if [[ $getContainerStateResult == "running" ]]; then echo "Container is running"; break; fi; 
        printProgress "Waiting for container in running state, currently it is $getContainerStateResult"; 
        sleep 10; 
        x=$(( $x + 1 ))
    done; 
}
fillConfigurationFile() {
    sed -i "/AV_IOTHUB=/d" "$repoRoot"/"$configuration_file"; echo "AV_IOTHUB=$AV_IOTHUB" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_IOTHUB_CONNECTION_STRING=/d" "$repoRoot"/"$configuration_file"; echo "AV_IOTHUB_CONNECTION_STRING=$AV_IOTHUB_CONNECTION_STRING" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_DEVICE_CONNECTION_STRING=/d" "$repoRoot"/"$configuration_file"; echo "AV_DEVICE_CONNECTION_STRING=$AV_DEVICE_CONNECTION_STRING" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_CONTAINER_REGISTRY=/d" "$repoRoot"/"$configuration_file"; echo "AV_CONTAINER_REGISTRY=$AV_CONTAINER_REGISTRY" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_CONTAINER_REGISTRY_DNS_NAME=/d" "$repoRoot"/"$configuration_file"; echo "AV_CONTAINER_REGISTRY_DNS_NAME=$AV_CONTAINER_REGISTRY_DNS_NAME" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_CONTAINER_REGISTRY_USERNAME=/d" "$repoRoot"/"$configuration_file"; echo "AV_CONTAINER_REGISTRY_USERNAME=$AV_CONTAINER_REGISTRY_USERNAME" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_CONTAINER_REGISTRY_PASSWORD=/d" "$repoRoot"/"$configuration_file"; echo "AV_CONTAINER_REGISTRY_PASSWORD=$AV_CONTAINER_REGISTRY_PASSWORD" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_SUBSCRIPTION_ID=/d" "$repoRoot"/"$configuration_file"; echo "AV_SUBSCRIPTION_ID=$AV_SUBSCRIPTION_ID" >> "$repoRoot"/"$configuration_file"   
    sed -i "/AV_AVA_PROVISIONING_TOKEN=/d" "$repoRoot"/"$configuration_file"; echo "AV_AVA_PROVISIONING_TOKEN=$AV_AVA_PROVISIONING_TOKEN" >> "$repoRoot"/"$configuration_file" 

}
initializeConfigurationFile() {
    sed -i "/AV_STORAGENAME=/d" "$repoRoot"/"$configuration_file"; echo "AV_STORAGENAME=" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_SASTOKEN=/d" "$repoRoot"/"$configuration_file"  ; echo "AV_SASTOKEN=" >> "$repoRoot"/"$configuration_file"
    sed -i "/AV_IOTHUB=/d" "$repoRoot"/"$configuration_file"; echo "AV_IOTHUB=" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_IOTHUB_CONNECTION_STRING=/d" "$repoRoot"/"$configuration_file"; echo "AV_IOTHUB_CONNECTION_STRING=" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_DEVICE_CONNECTION_STRING=/d" "$repoRoot"/"$configuration_file"; echo "AV_DEVICE_CONNECTION_STRING=" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_CONTAINER_REGISTRY=/d" "$repoRoot"/"$configuration_file"; echo "AV_CONTAINER_REGISTRY=" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_CONTAINER_REGISTRY_DNS_NAME=/d" "$repoRoot"/"$configuration_file"; echo "AV_CONTAINER_REGISTRY_DNS_NAME=" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_CONTAINER_REGISTRY_USERNAME=/d" "$repoRoot"/"$configuration_file"; echo "AV_CONTAINER_REGISTRY_USERNAME=" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_CONTAINER_REGISTRY_PASSWORD=/d" "$repoRoot"/"$configuration_file"; echo "AV_CONTAINER_REGISTRY_PASSWORD=" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_SUBSCRIPTION_ID=/d" "$repoRoot"/"$configuration_file"; echo "AV_SUBSCRIPTION_ID=" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_AVA_PROVISIONING_TOKEN=/d" "$repoRoot"/"$configuration_file"; echo "AV_AVA_PROVISIONING_TOKEN=" >> "$repoRoot"/"$configuration_file" 
}

createEdgeModule()
{

    access_token=$(az account get-access-token --query accessToken --output tsv)
    if [[ -z ${access_token} ]] ; then
        echo -e "${RED}\nFailed to get azure Token${NC}"
        exit 1
    fi
    headers="Authorization=Bearer ${access_token}"
    cmd="az rest --method put --uri \"https://management.azure.com/subscriptions/${AV_SUBSCRIPTION_ID}/resourceGroups/${AV_RESOURCE_GROUP}/providers/Microsoft.Media/videoAnalyzers/${AV_VIDEO_ANALYZER_ACCOUNT}/edgeModules/${AV_EDGE_MODULE}?api-version=2021-11-01-preview\" --body \"{}\" --headers \"Content-Type=application/json\" \"Authorization=Bearer ${access_token}\" --query name --output tsv"
    result=$(eval "$cmd")
    #echo "Result '${result}'"
    #echo "AV_EDGE_MODULE '${AV_EDGE_MODULE}'"
    
    if [ "${AV_EDGE_MODULE}" != "${result}" ] ; then
        printError "Failed to create edge module ${AV_EDGE_MODULE} "
        exit 1
    fi
}

getProvisioningToken()
{
    access_token=$(az account get-access-token --query accessToken --output tsv)
    if [[ -z ${access_token} ]] ; then
        echo  -e "${RED}\nFailed to get azure Token${NC}"
        exit 1
    fi
    headers="Authorization=Bearer ${access_token}"
    expiration_date=$(date '+%Y-%m-%d' -d "+2 years")
    cmd="az rest --method post --uri \"https://management.azure.com/subscriptions/${AV_SUBSCRIPTION_ID}/resourceGroups/${AV_RESOURCE_GROUP}/providers/Microsoft.Media/videoAnalyzers/${AV_VIDEO_ANALYZER_ACCOUNT}/edgeModules/${AV_EDGE_MODULE}/listProvisioningToken?api-version=2021-11-01-preview\" --body '{\"expirationDate\": \"${expiration_date}\"}' --headers \"Content-Type=application/json\" \"Authorization=Bearer ${access_token}\" --query token --output tsv"
    result=$(eval "$cmd")
    echo "${result}"
}

##############################################################################
#- buildWebAppContainer
##############################################################################
function buildWebAppContainer() {
    ContainerRegistryName="$1"
    apiModule="$2"
    imageName="$3"
    imageTag="$4"
    imageLatestTag="$5"

    targetDirectory="$(dirname "${BASH_SOURCE[0]}")/../../../../$apiModule"

    if [ ! -d "$targetDirectory" ]; then
            echo "Directory '$targetDirectory' does not exist."
            exit 1
    fi

    echo "Building and uploading the docker image for '$apiModule'"

    # Navigate to API module folder
    pushd "$targetDirectory" > /dev/null

    # Build the image
    echo "Building the docker image for '$imageName:$imageTag'"
    cmd="az acr build --registry $ContainerRegistryName --image ${imageName}:${imageTag} --image ${imageName}:${imageLatestTag} -f Dockerfile \
    --build-arg AV_PORT_RTSP=${AV_PORT_RTSP} --build-arg  AV_PORT_RTMP=${AV_PORT_RTMP} --build-arg  AV_PORT_SSL=${AV_PORT_SSL}  --build-arg AV_VIDEO_ONLY=true \
     --build-arg  AV_PORT_HTTP=${AV_PORT_HTTP} --build-arg  AV_PORT_HLS=${AV_PORT_HLS} --build-arg  AV_HOSTNAME=${AV_HOSTNAME} --build-arg  AV_COMPANYNAME=${AV_COMPANYNAME} \
      . --output none"

    printProgress "$cmd"
    eval "$cmd"

    
    popd > /dev/null

}


AV_PREFIXNAME="rtmprtspava$(shuf -i 1000-9999 -n 1)"
AV_RESOURCE_GROUP=${AV_PREFIXNAME}-rg
AV_RESOURCE_REGION=eastus2
AV_SERVICE=av-rtmp-rtsp-sink
AV_FLAVOR=ubuntu
AV_IMAGE_NAME=${AV_SERVICE}-${AV_FLAVOR} 
AV_IMAGE_FOLDER=av-services
AV_CONTAINER_NAME=${AV_SERVICE}-${AV_FLAVOR}-container
AV_EDGE_DEVICE=${AV_PREFIXNAME}-device
AV_EDGE_MODULE=${AV_PREFIXNAME}-device
AV_PATH_RTMP=live/stream
AV_VMNAME="$AV_PREFIXNAME"vm
AV_HOSTNAME="$AV_VMNAME"."$AV_RESOURCE_REGION".cloudapp.azure.com
AV_CONTAINERNAME=avchunks
AV_LOGIN=avvmadmin
AV_PASSWORD={YourPassword}
AV_COMPANYNAME=contoso
AV_PORT_HLS=8080
AV_PORT_HTTP=80
# use 8443 for SSL port to avoid conflict on IoT Edge with EdgeHub port
AV_PORT_SSL=8443
AV_PORT_RTMP=1935
AV_PORT_RTSP=8554
AV_TEMPDIR=$(mktemp -d)
ssh-keygen -t rsa -b 2048 -f ${AV_TEMPDIR}/outkey -q -P ""
AV_AUTHENTICATION_TYPE="sshPublicKey"
AV_SSH_PUBLIC_KEY="\"$(cat ${AV_TEMPDIR}/outkey.pub)\""
AV_SSH_PRIVATE_KEY="\"$(cat ${AV_TEMPDIR}/outkey)\""
AV_TEST_OPERATION="./operations.tracking.template.json"
AV_TEST_DEPLOYMENT="./deployment.tracking.json"
AV_TEST_VIDEO="https://avamedia.blob.core.windows.net/public/camera-300s.mkv"
AV_TEST_VIDEO_NAME="sample-tracking-video-001"
# Check if configuration file exists
if [[ ! -f "$repoRoot"/"$configuration_file" ]]; then
    cat > "$repoRoot"/"$configuration_file" << EOF
AV_RESOURCE_GROUP=${AV_RESOURCE_GROUP}
AV_RESOURCE_REGION=${AV_RESOURCE_REGION}
AV_SERVICE=${AV_SERVICE}
AV_FLAVOR=${AV_FLAVOR}
AV_IMAGE_NAME=${AV_IMAGE_NAME}
AV_IMAGE_FOLDER=${AV_IMAGE_FOLDER}
AV_CONTAINER_NAME=${AV_CONTAINER_NAME}
AV_EDGE_DEVICE=${AV_EDGE_DEVICE}
AV_EDGE_MODULE=${AV_EDGE_MODULE}
AV_PORT_RTMP=${AV_PORT_RTMP}
AV_PREFIXNAME=${AV_PREFIXNAME}
AV_VMNAME=${AV_VMNAME}
AV_HOSTNAME=${AV_HOSTNAME}
AV_CONTAINERNAME=${AV_CONTAINERNAME}
AV_STORAGENAME=
AV_SASTOKEN=
AV_LOGIN=${AV_LOGIN}
AV_PASSWORD=${AV_PASSWORD}
AV_COMPANYNAME=${AV_COMPANYNAME}
AV_PORT_HLS=${AV_PORT_HLS}
AV_PORT_HTTP=${AV_PORT_HTTP}
AV_PORT_SSL=${AV_PORT_SSL}
AV_PORT_RTMP=${AV_PORT_RTMP}
AV_PORT_RTSP=${AV_PORT_RTSP}
AV_IOTHUB=
AV_IOTHUB_CONNECTION_STRING=
AV_DEVICE_CONNECTION_STRING=
AV_CONTAINER_REGISTRY=
AV_CONTAINER_REGISTRY_DNS_NAME=
AV_CONTAINER_REGISTRY_USERNAME=
AV_CONTAINER_REGISTRY_PASSWORD=
AV_SUBSCRIPTION_ID=
AV_AVA_PROVISIONING_TOKEN=
AV_TEMPDIR=${AV_TEMPDIR}
AV_AUTHENTICATION_TYPE=${AV_AUTHENTICATION_TYPE}
AV_SSH_PUBLIC_KEY=${AV_SSH_PUBLIC_KEY}
AV_SSH_PRIVATE_KEY=${AV_SSH_PRIVATE_KEY}
AV_TEST_OPERATION=${AV_TEST_OPERATION}
AV_TEST_DEPLOYMENT=${AV_TEST_DEPLOYMENT}
AV_TEST_VIDEO=${AV_TEST_VIDEO}
AV_TEST_VIDEO_NAME=${AV_TEST_VIDEO_NAME}
EOF
fi
# Read variables in configuration file
export $(grep AV_RESOURCE_GROUP "$repoRoot"/"$configuration_file")
export $(grep AV_RESOURCE_REGION "$repoRoot"/"$configuration_file")
export $(grep AV_IMAGE_NAME "$repoRoot"/"$configuration_file")
export $(grep AV_IMAGE_FOLDER "$repoRoot"/"$configuration_file")
export $(grep AV_CONTAINER_NAME "$repoRoot"/"$configuration_file")
export $(grep AV_EDGE_DEVICE "$repoRoot"/"$configuration_file")
export $(grep AV_EDGE_MODULE "$repoRoot"/"$configuration_file")
export $(grep AV_PORT_RTMP "$repoRoot"/"$configuration_file")
export $(grep AV_PREFIXNAME "$repoRoot"/"$configuration_file")
export $(grep AV_VMNAME "$repoRoot"/"$configuration_file")
export $(grep AV_HOSTNAME "$repoRoot"/"$configuration_file")
export $(grep AV_CONTAINERNAME "$repoRoot"/"$configuration_file")
export $(grep AV_STORAGENAME "$repoRoot"/"$configuration_file")
export $(grep AV_SASTOKEN "$repoRoot"/"$configuration_file")
export $(grep AV_LOGIN "$repoRoot"/"$configuration_file"  )
export $(grep AV_PASSWORD "$repoRoot"/"$configuration_file" )
export $(grep AV_HOSTNAME "$repoRoot"/"$configuration_file")
export $(grep AV_COMPANYNAME "$repoRoot"/"$configuration_file")
export $(grep AV_PORT_HLS "$repoRoot"/"$configuration_file")
export $(grep AV_PORT_HTTP "$repoRoot"/"$configuration_file")
export $(grep AV_PORT_SSL "$repoRoot"/"$configuration_file")
export $(grep AV_PORT_RTMP "$repoRoot"/"$configuration_file")
export $(grep AV_PORT_RTSP "$repoRoot"/"$configuration_file")
export $(grep AV_IOTHUB "$repoRoot"/"$configuration_file")
export $(grep AV_IOTHUB_CONNECTION_STRING "$repoRoot"/"$configuration_file")
export $(grep AV_DEVICE_CONNECTION_STRING "$repoRoot"/"$configuration_file")
export $(grep AV_CONTAINER_REGISTRY "$repoRoot"/"$configuration_file")
export $(grep AV_CONTAINER_REGISTRY_DNS_NAME "$repoRoot"/"$configuration_file")
export $(grep AV_CONTAINER_REGISTRY_USERNAME "$repoRoot"/"$configuration_file")
export $(grep AV_CONTAINER_REGISTRY_PASSWORD "$repoRoot"/"$configuration_file")
export $(grep AV_SUBSCRIPTION_ID "$repoRoot"/"$configuration_file")
export $(grep AV_TEMPDIR "$repoRoot"/"$configuration_file" |  { read test; if [[ -z $test ]] ; then AV_TEMPDIR=$(mktemp -d) ; echo "AV_TEMPDIR=$AV_TEMPDIR" ; echo "AV_TEMPDIR=$AV_TEMPDIR" >> .avtoolconfig ; else echo $test; fi } )
export $(grep AV_AUTHENTICATION_TYPE "$repoRoot"/"$configuration_file")
export "$(grep AV_SSH_PUBLIC_KEY $repoRoot/$configuration_file)"
export "$(grep AV_SSH_PRIVATE_KEY $repoRoot/$configuration_file)"
export "$(grep AV_AVA_PROVISIONING_TOKEN $repoRoot/$configuration_file)" 
export "$(grep AV_TEST_OPERATION $repoRoot/$configuration_file)"
export "$(grep AV_TEST_DEPLOYMENT $repoRoot/$configuration_file)"
export "$(grep AV_TEST_VIDEO $repoRoot/$configuration_file)"
export "$(grep AV_TEST_VIDEO_NAME $repoRoot/$configuration_file)"



if [[ -z "${AV_TEMPDIR}" ]] ; then
    AV_TEMPDIR=$(mktemp -d)
    sed -i 's/AV_TEMPDIR=.*/AV_TEMPDIR=${AV_TEMPDIR}/' "$repoRoot"/"$configuration_file"
fi

if [[ "${action}" == "install" ]] ; then
    printMessage "Installing pre-requisite"
    printProgress "Installing azure cli"
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    az config set extension.use_dynamic_install=yes_without_prompt
    printProgress "Installing ffmpeg"
    sudo apt-get -y update
    sudo apt-get -y install ffmpeg
    sudo apt-get -y install  jq
    sudo apt-get -y install  dig
    # install the Azure IoT extension
    printProgress -e "Checking azure-iot extension."
    az extension show -n azure-iot -o none &> /dev/null
    if [ $? -ne 0 ]; then
        printProgress "azure-iot extension not found. Installing azure-iot."
        az extension add --name azure-iot &> /dev/null
        printProgress "azure-iot extension is now installed."
    else
        az extension update --name azure-iot &> /dev/null
        printProgress "azure-iot extension is up to date."														  
    fi
    if [ ! -f "${AV_TEMPDIR}"/camera-300s.mkv ]; then
        printProgress "Downloading content"
        wget --quiet https://avamedia.blob.core.windows.net/public/camera-300s.mkv -O "${AV_TEMPDIR}"/camera-300s.mkv     
    fi
    printProgress "Installing .Net 6.0 SDK "
    wget https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb -O "${AV_TEMPDIR}"/packages-microsoft-prod.deb
    sudo dpkg -i "${AV_TEMPDIR}"/packages-microsoft-prod.deb
    sudo apt-get update 
    sudo apt-get install -y apt-transport-https 
    sudo apt-get install -y dotnet-sdk-6.0
    sudo dotnet restore ../../../../src/avatool
    sudo dotnet build ../../../../src/avatool
    printMessage "Installing pre-requisites done"
    exit 0
fi
if [[ "${action}" == "login" ]] ; then
    printMessage "Login..."
    az login
    checkLoginAndSubscription
    printMessage  "Login done"
    exit 0
fi

if [[ "${action}" == "deploy" ]] ; then
    printMessage  "Deploying services..."
    checkLoginAndSubscription
    printProgress "Deploying IoT Hub and Azure Container Registry..."
    az group create -n ${AV_RESOURCE_GROUP}  -l ${AV_RESOURCE_REGION} 
    checkError
    az deployment group create -g ${AV_RESOURCE_GROUP} -n "${AV_RESOURCE_GROUP}dep" --template-file azuredeploy.iothub.json --parameters namePrefix=${AV_PREFIXNAME} containerName=${AV_CONTAINERNAME} iotHubSku="S1" -o json
    checkError
    outputs=$(az deployment group show --name ${AV_RESOURCE_GROUP}dep  -g ${AV_RESOURCE_GROUP} --query properties.outputs)
    AV_STORAGENAME=$(jq -r .storageAccount.value <<< $outputs)
    AV_SASTOKEN=$(jq -r .storageSasToken.value <<< $outputs)
    AV_VIDEO_ANALYZER_ACCOUNT=$(jq -r .videoAnalyzerName.value <<< $outputs)
    sed -i "/AV_STORAGENAME=/d" "$repoRoot"/"$configuration_file"; echo "AV_STORAGENAME=$AV_STORAGENAME" >> "$repoRoot"/"$configuration_file" 
    sed -i "/AV_SASTOKEN=/d" "$repoRoot"/"$configuration_file"  ; echo "AV_SASTOKEN=$AV_SASTOKEN" >> "$repoRoot"/"$configuration_file"
    sed -i "/AV_VIDEO_ANALYZER_ACCOUNT=/d" "$repoRoot"/"$configuration_file"; echo "AV_VIDEO_ANALYZER_ACCOUNT=$AV_VIDEO_ANALYZER_ACCOUNT" >> "$repoRoot"/"$configuration_file" 

    # tempo waiting 
    sleep 60
    RESOURCES=$(az resource list --resource-group "${AV_RESOURCE_GROUP}" --query '[].{name:name,"Resource Type":type}' -o table)
    # capture resource configuration in variables
    AV_IOTHUB=$(echo "${RESOURCES}" | awk '$2 ~ /Microsoft.Devices\/IotHubs$/ {print $1}')
    AV_IOTHUB_CONNECTION_STRING=$(az iot hub connection-string show --hub-name ${AV_IOTHUB} --query='connectionString')

    createEdgeModule
    checkError


    AV_AVA_PROVISIONING_TOKEN=$(getProvisioningToken)
    checkError

    if [ -z ${AV_AVA_PROVISIONING_TOKEN} ]; then
        printError "IOTHub provisioning Token not defined"
        exit 1        
    fi
    
    printProgress "Azure Video Analyzer provisioning Token: $AV_AVA_PROVISIONING_TOKEN"
    sed -i "/AV_AVA_PROVISIONING_TOKEN=/d" "$repoRoot"/"$configuration_file"; echo "AV_AVA_PROVISIONING_TOKEN=$AV_AVA_PROVISIONING_TOKEN" >> "$repoRoot"/"$configuration_file" 

    AV_CONTAINER_REGISTRY=$(echo "${RESOURCES}" | awk '$2 ~ /Microsoft.ContainerRegistry\/registries$/ {print $1}')
    AV_CONTAINER_REGISTRY_USERNAME=$(az acr credential show -n $AV_CONTAINER_REGISTRY --query 'username' | tr -d \")
    AV_CONTAINER_REGISTRY_PASSWORD=$(az acr credential show -n $AV_CONTAINER_REGISTRY --query 'passwords[0].value' | tr -d \")

    # configure the hub for an edge device
    printProgress "Registering device..."
    if test -z "$(az iot hub device-identity list -n $AV_IOTHUB | grep "deviceId" | grep $AV_EDGE_DEVICE)"; then
        az iot hub device-identity create --hub-name $AV_IOTHUB --device-id $AV_EDGE_DEVICE --edge-enabled -o none
        checkError
    fi
    AV_DEVICE_CONNECTION_STRING=$(az iot hub device-identity connection-string show --device-id $AV_EDGE_DEVICE --hub-name $AV_IOTHUB --query='connectionString')
    AV_DEVICE_CONNECTION_STRING=${AV_DEVICE_CONNECTION_STRING//\//\\/} 

    printProgress "Deploying Virtual Machine..."
    getPublicIPAddress || true
    cmd="az deployment group create -g ${AV_RESOURCE_GROUP} -n \"${AV_RESOURCE_GROUP}dep\" --template-file azuredeploy.vm.json --parameters namePrefix=${AV_PREFIXNAME} vmAdminUsername=${AV_LOGIN} authenticationType=${AV_AUTHENTICATION_TYPE} vmAdminPasswordOrKey=${AV_SSH_PUBLIC_KEY} sshClientIPAddress="$getPublicIPAddressResult" storageAccountName=${AV_STORAGENAME} deviceConnectionString=\"${AV_DEVICE_CONNECTION_STRING//\"/}\"  portHTTP=${AV_PORT_HTTP} portSSL=${AV_PORT_SSL} portHLS=${AV_PORT_HLS}  portRTMP=${AV_PORT_RTMP} portRTSP=${AV_PORT_RTSP}  -o json"
    echo "${cmd}"
    eval "${cmd}"
    #az deployment group create -g ${AV_RESOURCE_GROUP} -n "${AV_RESOURCE_GROUP}dep" --template-file azuredeploy.vm.json --parameters namePrefix=${AV_PREFIXNAME} vmAdminUsername=${AV_LOGIN} authenticationType=${AV_AUTHENTICATION_TYPE} vmAdminPasswordOrKey=${AV_SSH_PUBLIC_KEY}  storageAccountName=${AV_STORAGENAME} customData="${CUSTOM_STRING_BASE64}"  portRTMP=${AV_PORT_RTMP} portRTSP=${AV_PORT_RTSP}  -o json
    checkError
    
    printProgress "\nResource group now contains these resources:"
    RESOURCES=$(az resource list --resource-group "${AV_RESOURCE_GROUP}" --query '[].{name:name,"Resource Type":type}' -o table)
    printProgress "${RESOURCES}"
    VNET=$(echo "${RESOURCES}" | awk '$2 ~ /Microsoft.Network\/virtualNetworks$/ {print $1}')
    AV_CONTAINER_REGISTRY_DNS_NAME=$(az acr show -n "${AV_CONTAINER_REGISTRY}" --query loginServer --output tsv)

    printProgress "Building container image..."
    APP_VERSION=$(date +"%Y%M%d.%H%M%S")
    buildWebAppContainer "${AV_CONTAINER_REGISTRY_DNS_NAME}" "./envs/container/docker/av-rtmp-rtsp-sink/${AV_FLAVOR}" ${AV_IMAGE_FOLDER}/${AV_IMAGE_NAME}  "${APP_VERSION}" "latest" 
    checkError    
    printProgress  "Image successfully built"

    printProgress ""
    printProgress "Deploying modules on device ${AV_EDGE_DEVICE} in IoT Edge ${AV_IOTHUB} " 
    printProgress ""
    # Wait 120 seconds before deploying containers 
    sleep 120    
    setContainerState "running"
    # Wait 1 minute to complete the deployment 
    sleep 60
    getContainerState 
    if [[ $getContainerStateResult != "running" ]]; then
        printProgress "Container state is not running: $getContainerStateResult"    
        printProgress "Content of the template file used to start the container: "
        cat ${AV_TEMPDIR}/deployment.template.json        
        setContainerState "running"
        sleep 30
        getContainerState 
    fi    
    printProgress "Container state: $getContainerStateResult"    
    fillConfigurationFile

    printProgress "
Content of the .env file which can be used with the Azure IoT Tools in Visual Studio Code:    
    "
    # write .env file for edge deployment
    echo "SUBSCRIPTION_ID=\"$AV_SUBSCRIPTION_ID\"" > ./.env
    echo "RESOURCE_GROUP=\"$AV_RESOURCE_GROUP\"" >> ./.env
    echo "IOTHUB_CONNECTION_STRING=$AV_IOTHUB_CONNECTION_STRING" >> ./.env
    echo "VIDEO_INPUT_FOLDER_ON_DEVICE=\"/home/avaedgeuser/samples/input\""  >> ./.env
    echo "VIDEO_OUTPUT_FOLDER_ON_DEVICE=\"/var/media\""  >> ./.env
    echo "APPDATA_FOLDER_ON_DEVICE=\"/var/lib/azuremediaservices\""  >> ./.env
    echo "CONTAINER_REGISTRY_USERNAME_myacr=$AV_CONTAINER_REGISTRY_USERNAME" >> ./.env
    echo "CONTAINER_REGISTRY_PASSWORD_myacr=$AV_CONTAINER_REGISTRY_PASSWORD" >> ./.env
    cat ./.env

    printProgress "
Content of the appsettings.json file which can be used with the Azure IoT Tools in Visual Studio Code:    
    "
    # write appsettings for sample code
    echo "{" > ./appsettings.json
    echo "    \"IoThubConnectionString\" : $AV_IOTHUB_CONNECTION_STRING," >>  ./appsettings.json
    echo "    \"deviceId\" : \"$AV_EDGE_DEVICE\"," >>  ./appsettings.json
    echo "    \"moduleId\" : \"avaedge\"" >>  ./appsettings.json
    echo -n "}" >>  ./appsettings.json
    cat ./appsettings.json

    printProgress "

Content of operations.json file which can be used with the Azure Cloud To Device Console App:
    "
    # write operations.json for sample code
    sed "s/{PORT_RTSP}/${AV_PORT_RTSP}/g" < ${AV_TEST_OPERATION} 
    printProgress "
Deployment parameters:    
    "
    echo "AVA_PROVISIONING_TOKEN=${AV_AVA_PROVISIONING_TOKEN}"
    echo "IOTHUB=${AV_IOTHUB}"
    echo "IOTHUB_CONNECTION_STRING=${AV_IOTHUB_CONNECTION_STRING}"
    echo "DEVICE_CONNECTION_STRING=${AV_DEVICE_CONNECTION_STRING}"
    echo "CONTAINER_REGISTRY=${AV_CONTAINER_REGISTRY}"
    echo "CONTAINER_REGISTRY_DNS_NAME=${AV_CONTAINER_REGISTRY_DNS_NAME}"
    echo "CONTAINER_REGISTRY_USERNAME=${AV_CONTAINER_REGISTRY_USERNAME}"
    echo "CONTAINER_REGISTRY_PASSWORD=${AV_CONTAINER_REGISTRY_PASSWORD}"
    echo "AV_HOSTNAME=${AV_HOSTNAME}"
    echo "SSH command: ssh ${AV_LOGIN}@${AV_HOSTNAME}"
    echo "RTMP URL: rtmp://${AV_HOSTNAME}:${AV_PORT_RTMP}/live/stream"
    echo "RTSP URL: rtsp://${AV_HOSTNAME}:${AV_PORT_RTSP}/live/stream"
    echo "HLS  URL: http://${AV_HOSTNAME}:${AV_PORT_HLS}/live/stream.m3u8"
    echo "HTTP URL: http://${AV_HOSTNAME}:${AV_PORT_HTTP}/player.html"
    echo "SSL  URL: https://${AV_HOSTNAME}:${AV_PORT_SSL}/player.html" 
    echo -e "${GREEN}Deployment done${NC}"
    exit 0
fi

if [[ "${action}" == "undeploy" ]] ; then
    printMessage "Undeploying service..."
    checkLoginAndSubscription
    az group delete -n ${AV_RESOURCE_GROUP} --yes
    initializeConfigurationFile
    printMessage "Undeployment done"
    exit 0
fi

if [[ "${action}" == "start" ]] ; then
    printMessage "Starting service..."
    APP_VERSION=$(date +"%Y%M%d.%H%M%S")
    buildWebAppContainer "${AV_CONTAINER_REGISTRY_DNS_NAME}" "./envs/container/docker/av-rtmp-rtsp-sink/${AV_FLAVOR}" ${AV_IMAGE_FOLDER}/${AV_IMAGE_NAME}  "${APP_VERSION}" "latest" 

    checkLoginAndSubscription
    startContainer
    printMessage "Container started"
    exit 0
fi

if [[ "${action}" == "stop" ]] ; then
    printMessage "Stopping service..."
    checkLoginAndSubscription
    stopContainer
    printMessage "Container stopped"
    exit 0
fi
if [[ "${action}" == "status" ]] ; then
    printMessage "Checking status..."
    checkLoginAndSubscription
    getContainerState 
    printProgress "$getContainerStateResult"
    printMessage "Container status done"
    exit 0
fi

if [[ "${action}" == "test" ]] ; then
    printMessage "Launching tests..."
    if [[ ! -z $deployment ]]; then
        AV_TEST_DEPLOYMENT=$deployment
    fi
    if [[ ! -z $operation ]]; then
        AV_TEST_OPERATION=$operation
    fi
    if [[ ! -z $video ]]; then
        AV_TEST_VIDEO=$video
    fi
    if [[ ! -z $videoname ]]; then
        AV_TEST_VIDEO_NAME=$videoname
    fi

    if [[ ! -e $AV_TEST_DEPLOYMENT ]]; then
        printError "Test failed - deployment file '${AV_TEST_DEPLOYMENT}' not found"
        exit 1    
    fi
    if [[ ! -e $AV_TEST_OPERATION ]]; then
        printError "Test failed - operation file '${AV_TEST_OPERATION}' not found"
        exit 1
    fi

    printProgress "Tests variables: "
    printProgress "AV_TEST_DEPLOYMENT: ${AV_TEST_DEPLOYMENT}"
    printProgress "AV_TEST_OPERATION: ${AV_TEST_OPERATION}"
    printProgress "AV_TEST_VIDEO: ${AV_TEST_VIDEO}"
    printProgress "AV_TEST_VIDEO_NAME: ${AV_TEST_VIDEO_NAME}"
    
    # Available videos for the tests: 
    # https://avamedia.blob.core.windows.net/public/camera-300s.mkv    
    # https://avamedia.blob.core.windows.net/public/lots_284.mkv   
    # https://avamedia.blob.core.windows.net/public/lots_015.mkv   
    # https://avamedia.blob.core.windows.net/public/t2.mkv   
    # https://avamedia.blob.core.windows.net/public/retailshop-15fps.mkv
    # Locally:
    # ../../../../content/cafetaria.mkv   
    # ../../../../content/bus.mkv   
    # ../../../../content/parking.mkv   
    # ../../../../content/t2.mkv   
    # ../../../../content/camera-300s.mkv  
    # ../../../../content/retailshop.mkv   

    if [[ "${AV_TEST_VIDEO}" =~ ^http.* ]]; then
        printProgress "Downloading content"
        wget --quiet ${AV_TEST_VIDEO}  -O "${AV_TEMPDIR}"/camera-300s.mkv
    else
        if [[ "${AV_TEST_VIDEO}" != "live" ]]; then
            if [[ -f ${AV_TEST_VIDEO} ]]; then
                printProgress "Copying content"
                cp ${AV_TEST_VIDEO}  "${AV_TEMPDIR}"/camera-300s.mkv
            else
                printError "Test failed - input file '${AV_TEST_VIDEO}' not found"
                exit 1
            fi
        fi
    fi
    printProgress "Testing service..."
    stopContainer
    startContainer    
    checkLoginAndSubscription
    # Archive on Azure Storage with rtmp/rtsp disable 
    # cmd="az storage blob delete-batch -s ${AV_CONTAINERNAME} --account-name ${AV_STORAGENAME} --pattern *.mp4 --sas-token \"${AV_SASTOKEN}\""
    # eval "$cmd"
    #
    if [[ "${AV_TEST_VIDEO}" != "live" ]]; then
        printProgress ""
        printProgress "Start RTMP Streaming towards rtmp://${AV_HOSTNAME}:${AV_PORT_RTMP}/${AV_PATH_RTMP}..."
        printProgress ""
        printProgress "RTMP Streaming command: ffmpeg -nostats -loglevel 0 -re -stream_loop -1 -i "${AV_TEMPDIR}"/camera-300s.mkv -codec copy -bsf:v h264_mp4toannexb -f flv rtmp://${AV_HOSTNAME}:${AV_PORT_RTMP}/${AV_PATH_RTMP}"
        ffmpeg -nostats -loglevel 0 -re -stream_loop -1 -i "${AV_TEMPDIR}"/camera-300s.mkv -codec copy -bsf:v h264_mp4toannexb -f flv rtmp://${AV_HOSTNAME}:${AV_PORT_RTMP}/${AV_PATH_RTMP} &
    else
        printProgress ""
        printProgress "Please start your RTMP Streamer towards rtmp://${AV_HOSTNAME}:${AV_PORT_RTMP}/${AV_PATH_RTMP}..."
        printProgress ""
    fi
    printProgress ""
    printProgress " Wait 30 seconds before consuming the outputs..."
    printProgress ""
    sleep 30
    printProgress ""
    printProgress "Testing output RTMP..."
    printProgress ""
    printProgress "Output RTMP: rtmp://${AV_HOSTNAME}:${AV_PORT_RTMP}/${AV_PATH_RTMP}"
    printProgress "RTMP Command: ffmpeg -nostats -loglevel 0 -re -rw_timeout 20000000 -i rtmp://${AV_HOSTNAME}:${AV_PORT_RTMP}/${AV_PATH_RTMP} -c copy -flags +global_header -f segment -segment_time 5 -segment_format_options movflags=+faststart -t 00:00:20  -reset_timestamps 1 "${AV_TEMPDIR}"/testrtmp%d.mp4  "
    ffmpeg -nostats -loglevel 0 -re -rw_timeout 20000000 -i rtmp://${AV_HOSTNAME}:${AV_PORT_RTMP}/${AV_PATH_RTMP} -c copy -flags +global_header -f segment -segment_time 5 -segment_format_options movflags=+faststart -t 00:00:20  -reset_timestamps 1 "${AV_TEMPDIR}"/testrtmp%d.mp4  || true
    checkOutputFiles testrtmp || true
    if [[ "$checkOutputFilesResult" == "0" ]] ; then
        printError  "RTMP Test failed - check files testrtmpx.mp4"
        kill %1 2&> /dev/null || true
        exit 0
    fi
    printProgress "Testing output RTMP successful"
    
    printProgress ""
    printProgress "Testing output HLS..."
    printProgress ""
    printProgress "Output HLS:  http://${AV_HOSTNAME}:${AV_PORT_HLS}/live/stream.m3u8"
    printProgress "HLS Command: ffmpeg -nostats -loglevel 0  -i http://${AV_HOSTNAME}:${AV_PORT_HLS}/live/stream.m3u8 -c copy -flags +global_header -f segment -segment_time 5 -segment_format_options movflags=+faststart -t 00:00:20  -reset_timestamps 1 "${AV_TEMPDIR}"/testhls%d.mp4 "
    ffmpeg -nostats -loglevel 0  -i http://${AV_HOSTNAME}:${AV_PORT_HLS}/live/stream.m3u8 -c copy -flags +global_header -f segment -segment_time 5 -segment_format_options movflags=+faststart -t 00:00:20  -reset_timestamps 1 "${AV_TEMPDIR}"/testhls%d.mp4  || true
    checkOutputFiles testhls || true
    if [[ "$checkOutputFilesResult" == "0" ]] ; then
        printError "HLS Test failed - check files testhlsx.mp4"
        kill %1 2&> /dev/null || true
        exit 0
    fi
    printProgress "Testing output HLS successful"

    printProgress ""
    printProgress "Testing output RTSP..."
    printProgress ""
    printProgress "Output RTSP: rtsp://${AV_HOSTNAME}:${AV_PORT_RTSP}/rtsp/stream"
    printProgress "RTSP Command: ffmpeg -nostats -loglevel 0 -rtsp_transport tcp  -i rtsp://${AV_HOSTNAME}:${AV_PORT_RTSP}/rtsp/stream -c copy -flags +global_header -f segment -segment_time 5 -segment_format_options movflags=+faststart -t 00:00:20 -reset_timestamps 1 "${AV_TEMPDIR}"/testrtsp%d.mp4"
    ffmpeg -nostats -loglevel 0  -rtsp_transport tcp  -i rtsp://${AV_HOSTNAME}:${AV_PORT_RTSP}/rtsp/stream -c copy -flags +global_header -f segment -segment_time 5 -segment_format_options movflags=+faststart -t 00:00:20 -reset_timestamps 1 "${AV_TEMPDIR}"/testrtsp%d.mp4 || true
    checkOutputFiles testrtsp || true
    if [[ "$checkOutputFilesResult" == "0" ]] ; then
        printError "RTSP Test failed - check files testrtsp.mp4"
        kill %1 2&> /dev/null || true
        exit 0
    fi
    printProgress "Testing output RTSP successful"

    # Archive on Azure Storage with rtmp/rtsp disable 
    #echo ""
    #echo "Testing output on Azure Storage..."    
    #echo ""
    #echo "Azure Storage URL: https://${AV_STORAGENAME}.blob.core.windows.net/${AV_CONTAINERNAME}?${AV_SASTOKEN}&comp=list&restype=container"
    # wait 120 seconds to be sure the first chunks are copied on Azure Storage
    #echo ""
    #echo " Wait 180 seconds  to be sure the first chunks are copied on Azure Storage..."
    #echo ""    
    #sleep 180
    #wget --quiet -O "${AV_TEMPDIR}"/testazure.xml "https://${AV_STORAGENAME}.blob.core.windows.net/${AV_CONTAINERNAME}?${AV_SASTOKEN}&comp=list&restype=container"
    #blobs=($(grep -oP '(?<=Name>)[^<]+' "${AV_TEMPDIR}/testazure.xml"))
    #bloblens=($(grep -oP '(?<=Content-Length>)[^<]+' "${AV_TEMPDIR}/testazure.xml"))

    #teststorage=0
    #for i in ${!blobs[*]}
    #do
    #    echo "File: ${blobs[$i]} size: ${bloblens[$i]}"
    #    teststorage=1
    #done
    #if [[ "$teststorage" == "0" ]] ; then
    #    echo "Azure Storage Test failed - check files https://${AV_STORAGENAME}.blob.core.windows.net/${AV_CONTAINERNAME}?${AV_SASTOKEN}&comp=list&restype=container"
    #    kill %1
    #    exit 0
    #fi

    printProgress ""
    printProgress "Testing AVA..."
    printProgress ""
    # write operations.json for sample code
    sed "s/{AV_PORT_RTSP}/${AV_PORT_RTSP}/g" < ${AV_TEST_OPERATION} > ${AV_TEMPDIR}/operations.json 
    sed -i "s/{AV_HOSTNAME}/${AV_HOSTNAME}/" ${AV_TEMPDIR}/operations.json
    sed -i "s/{AV_TEST_VIDEO_NAME}/${AV_TEST_VIDEO_NAME}/" ${AV_TEMPDIR}/operations.json
    cat ${AV_TEMPDIR}/operations.json 
    printProgress "Activating the AVA Graph"
    cmd="sudo dotnet run --project ../../../../src/avatool --runoperations --operationspath \"${AV_TEMPDIR}/operations.json\" --connectionstring $AV_IOTHUB_CONNECTION_STRING --device \"$AV_EDGE_DEVICE\"  --module avaedge --lastoperation livePipelineGet"
    printProgress "$cmd"
    eval "$cmd"
    checkError

    printProgress "Receiving the AVA events during 180 seconds"
    cmd="sudo dotnet run --project ../../../../src/avatool --readevents --connectionstring $AV_IOTHUB_CONNECTION_STRING --timeout 180000"
    printProgress "$cmd"
    eval "$cmd" 2>&1 | tee ${AV_TEMPDIR}/events.txt
    checkError

    printProgress "Deactivating the AVA Graph"
    cmd="sudo dotnet run --project ../../../../src/avatool --runoperations --operationspath \"${AV_TEMPDIR}/operations.json\" --connectionstring $AV_IOTHUB_CONNECTION_STRING --device \"$AV_EDGE_DEVICE\"  --module avaedge --firstoperation livePipelineGet"
    printProgress "$cmd"
    eval "$cmd"
    checkError

    grep -i '"type": ' ${AV_TEMPDIR}/events.txt &> /dev/null
    status=$?
    if [ $status -ne 0 ]; then
        printError "AVA Test Failed to detect motion events in the results file"
        kill %1 2&> /dev/null || true
        exit $status
    fi

    #jobs
    kill %1 2&> /dev/null || true
    printMessage "TESTS SUCCESSFUL"
    exit 0
fi
