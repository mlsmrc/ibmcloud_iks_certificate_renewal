#!/bin/bash

# MIT License
#
# Copyright (c) 2020 mlsmrc
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Set DEBUG=<random_string> to read values from values.sh script
[ ! -z $DEBUG ] && source values.sh

CM_FULL_CRN="crn:v1:bluemix:public:cloudcerts:${CM_REGION}:a/$CLOUD_ACCOUNT_CRN:$CM_INSTANCE_CRN::"
CM_URL="https://"${CM_REGION}".certificate-manager.cloud.ibm.com/"
CM_API_V3="api/v3/"
CM_API_V2="api/v2/"
IAM_TOKEN_URL="https://iam.cloud.ibm.com/identity/token"
API_V3_ENDPOINT=${CM_URL}${CM_API_V3}
API_V2_ENDPOINT=${CM_URL}${CM_API_V2}
RC=0
YES=0
NO=1

# Using these folder to store temporarly the certificate
BACKUP_FOLDER="backup"
BACKUP_CERT_CRT_PATH=$BACKUP_FOLDER"/"$(basename $CERT_CRT_PATH)
BACKUP_CERT_KEY_PATH=$BACKUP_FOLDER"/"$(basename $CERT_KEY_PATH)

# Using this annotation for new/backup secret
ANNOTATION="author=certificate_renewal_agent"

################################ UTILS ################################

function crnEncode()
{
  local url=$1
  python -c "import urllib, sys; print urllib.quote(sys.argv[1])" "$url"
}

function _echo() { echo $1 >> $LOG_FILE; }

function isBase64EncodedCrt()
{
  local CRT_FILE_NAME=$1
  echo $CRT_FILE_NAME | grep -q "END CERTIFICATE\|BEGIN CERTIFICATE" && return 1
  return 0
}
function isBase64EncodedKubeSecret()
{
  local SECRET_NAME=$1
  local crt_file_name=$(basename $2)
  kubectl get secret $SECRET_NAME -n $SECRET_NAMESPACE -o json | \
                  jq --arg name $crt_file_name -r '.data[$name]' | \
                  grep -q "END CERTIFICATE\|BEGIN CERTIFICATE" && return 1
  return 0
}
function checkArgs()
{
  local rc=0
  local vars="CM_INSTANCE_CRN \
              CLOUD_ACCOUNT_CRN \
              CM_REGION HOSTNAME_DOMAINAME \
              CERT_CRT_PATH \
              CERT_KEY_PATH \
              CLOUD_API_KEY \
              SECRET_NAME \
              SECRET_NAMESPACE \
              CLOUD_REGION \
              CLOUD_RESOURCE_GROUP \
              CLUSTER_ID \
              KUBE_DEPLOY_NAME"

  for var in $vars; do
    [ -z "${!var}" ] && _einfo "Variable $var is missing" && rc=1
  done

  return $rc
}

################################ Logs ###############################
function checkLogFile()
{
  [[ "$LOG_FILE" == "/dev/stdout" ]] && { LOG_FILE="/dev/stderr"; _echo "/dev/stdout is not allowed for logs"; }
  _echo "Using $LOG_FILE for logs"
  _echo ""
}

################################ IAM ################################
function getIamToken()
{
  [ $# -ne 2 ] && _echo "usage getIamToken <api_token> <silent>" && return 1
  local API_KEY=$1
  local SILENT=$2
  local token=$(curl --silent -X POST -H "Content-Type: application/x-www-form-urlencoded" -H "Accept: application/json" \
                              -d "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${API_KEY}" $IAM_TOKEN_URL | \
                              jq .access_token | tr -d "\"")

  if [[ "$token" == "null" ]]; then
    [ $SILENT -eq $NO ] && _echo "Client not authenticated"
    return 1
  else
    [ $SILENT -eq $NO ] && _echo "Client authenticated"
    echo $token
    return 0
  fi
}

############################# IBMCloud #############################
function ibmCloudLogin()
{
  _echo "IBMCloud login"
  _echo "Region $CLOUD_REGION"
  _echo "Resource group: $CLOUD_RESOURCE_GROUP"
  yes | ibmcloud login --apikey $CLOUD_API_KEY -r $CLOUD_REGION -g $CLOUD_RESOURCE_GROUP
  return $?
}

function kubeconfigRefresh()
{
  _echo "Refreshing Cluster '$CLUSTER_ID' token"
  ibmcloud ks cluster config --cluster $CLUSTER_ID
  return $?
}
################################ CM ################################
function getJsonCertFromCertManager()
{
  [ $# -ne 2 ] && _echo "usage getJsonCertFromCertManager <api_token> <cert_crn>" && return 1
  API_KEY=$1
  CERT_CRN=$2

  token=$(getIamToken ${API_KEY} $YES)
  encodedCrn=$(crnEncode ${CERT_CRN})
  curl --silent -H "Authorization: Bearer $token"  ${API_V2_ENDPOINT}"certificate/"${encodedCrn}
}
function getJsonCertsFromCertManager()
{
  [ $# -ne 2 ] && _echo "usage getJsonCertsFromCertManager <api_token> <cert_folder_crn>" && return 1
  local API_KEY=$1
  local CM_FULL_CRN=$2

  local token=$(getIamToken ${API_KEY} $YES)
  local encodedCrn=$(crnEncode ${CM_FULL_CRN})
  curl --silent -H "Authorization: Bearer $token" ${API_V3_ENDPOINT}${encodedCrn}"/certificates/"
}

function getCrnCertFromCertManager()
{
  [ $# -ne 3 ] && _echo "usage getCrnCertFromCertManager <api_token> <cm_crn> <domain>" && return 1
  API_KEY=$1
  CM_FULL_CRN=$2
  DOMAIN=$3

  _echo "Getting Certificate CRN of $DOMAIN"
  jsonCerts=$(getJsonCertsFromCertManager $API_KEY $CM_FULL_CRN)
  [[  "$(echo $jsonCerts | jq .message)" == "Unauthorized" ]] && return 1

  local jsonCert=$(echo $jsonCerts | jq .certificates | jq --arg d $DOMAIN '[ .[] | select(.domains[] | contains ($d))]')

  if [ $(echo $jsonCert | jq length) -eq 1 ]; then
    local id=$(cat jsonCert | jq -r .[0]._id)
    _echo "CRN Found: $id"
    echo $id
    return 0
  fi

  _echo "Certificate CRN not found"
  return 1
}

function getValueFileFromCert()
{
  [ $# -ne 5 ] && _echo "usage getCertFileFromCert <api_token> <cm_crn> <domain> <value> <file_name>" && return 1
  API_KEY=$1
  CM_FULL_CRN=$2
  DOMAIN=$3
  VALUE=$4
  FILE_NAME=$5

  # Get Certificate CRN
  CERT_CRN=$(getCrnCertFromCertManager $API_KEY $CM_FULL_CRN $DOMAIN)
  [ -z "$CERT_CRN" ] && return 1

  # Create directory
  mkdir -p $(dirname "$FILE_NAME")

  # Make sure the file is empty
  cat /dev/null > $FILE_NAME

  _echo "Getting '$VALUE' file $DOMAIN ($CM_FULL_CRN)"
  _echo "Storing it to $FILE_NAME"

  # Download file locally
  getJsonCertFromCertManager $API_KEY $CERT_CRN | jq -r $VALUE > $FILE_NAME

  # Check file correctness
  [ -z "$(cat $FILE_NAME)" ] && _echo "Certificate Key empty" && return 1
  [[ "$(cat $FILE_NAME)" == "null" ]] && _echo "Certificate Key not exists" && return 1

  _echo "Done"
}

function getCrtFileFromCert()
{
  getValueFileFromCert $1 $2 $3 ".data.content" $4
  return $?
}

function getKeyFileFromCert()
{
  getValueFileFromCert $1 $2 $3 ".data.priv_key" $4
  return $?
}

################################ K8s ################################
function secretExists()
{
  _echo "Check if secret '$SECRET_NAME' exists"
  kubectl get secret $SECRET_NAME -n $SECRET_NAMESPACE &>1 >> $LOG_FILE
  local rc=$?

  [ $rc -eq 0 ] && _echo "Secret found" \
                || _echo "Secret not exists"

  return $rc
}
function namespaceExists()
{
  _echo "Check if provided namespace exists $SECRET_NAMESPACE"
  kubectl get ns $SECRET_NAMESPACE &>1 >> $LOG_FILE
  local rc=$?

  [ $rc -eq 0 ] && _echo "Namespace found" \
                || _echo "Namespace not exists"

  return $rc
}

function createKubeSecret()
{
  _echo "Creating Kubernetes secret '$SECRET_NAME' on namespace '$SECRET_NAMESPACE' based on $CERT_CRT_PATH/$CERT_KEY_PATH"

  kubectl create secret generic $SECRET_NAME -n $SECRET_NAMESPACE --from-file=$(basename $CERT_CRT_PATH)=$CERT_CRT_PATH \
                                                                  --from-file=$(basename $CERT_KEY_PATH)=$CERT_KEY_PATH

  annotateKubeSecret $SECRET_NAME
}

function annotateKubeSecret()
{
  local secret_name=$1
  kubectl annotate secret $secret_name -n $SECRET_NAMESPACE $ANNOTATION --overwrite
}

function removeBackupKubeSecretFolder()
{
  _echo "Removing backup folder ${BACKUP_FOLDER}"
  rm -rf ${BACKUP_FOLDER}
}

function backupKubeSecret()
{
  local crt_file_name=$(basename $BACKUP_CERT_CRT_PATH)
  local key_file_name=$(basename $BACKUP_CERT_KEY_PATH)
  local secret_name_backup="${SECRET_NAME}-backup"

  _echo "Deleting old backup if exists"
  kubectl delete --force --grace-period=0 secret ${secret_name_backup} -n $SECRET_NAMESPACE

  _echo "Backupping original secret ${SECRET_NAME} > ${secret_name_backup}"
  kubectl get secret ${SECRET_NAME} -n $SECRET_NAMESPACE -o yaml | \
          sed "s/${SECRET_NAME}/${secret_name_backup}/g" | \
          kubectl create -f -

  # Annotating the backup secret
  annotateKubeSecret $secret_name_backup

  if [ $? -ne 0 ]; then
    _echo "Error creating backup secret"
    return 1
  fi

  return 0
}
function restartDeployment()
{
  _echo "Restarting deployment $KUBE_DEPLOY_NAME"
  kubectl rollout restart deployment $KUBE_DEPLOY_NAME -n $SECRET_NAMESPACE

  _echo "Getting deployment $KUBE_DEPLOY_NAME rollout status"
  kubectl rollout status deployment $KUBE_DEPLOY_NAME -n $SECRET_NAMESPACE
}
function deleteOldKubeSecret()
{
  _echo "Deleting old secret"
  kubectl delete --force --grace-period=0 secret $SECRET_NAME -n $SECRET_NAMESPACE >> $LOG_FILE
}

#######################################################
# Main
#######################################################

# Validating log file
checkLogFile

# Variables validation
checkArgs || exit 10

# Validate api token
getIamToken $CLOUD_API_KEY $NO &>/dev/null || exit 11

# Perform IBM Cloud login
ibmCloudLogin $CLOUD_API_KEY || exit 12

# Get kubeconfig from your IBM Cloud Kubernetes cluster
kubeconfigRefresh $CLOUD_API_KEY || exit 13

# Check if namespace exists
namespaceExists || exit 20

# Check if secret exists
secretExists || exit 21

# Download new crt/key files locally from IBM Cloud Certificate Manager
getCrtFileFromCert $CLOUD_API_KEY $CM_FULL_CRN $HOSTNAME_DOMAINAME $CERT_CRT_PATH || exit 22
getKeyFileFromCert $CLOUD_API_KEY $CM_FULL_CRN $HOSTNAME_DOMAINAME $CERT_KEY_PATH || exit 23

# Creating Kubernetes secret backup
backupKubeSecret || exit 24

# Deleting old Kubernetes secret
deleteOldKubeSecret || exit 25

# Creating new Kubernetes secret
createKubeSecret || exit 26

# Removing backup
removeBackupKubeSecretFolder

# Rollout new deployment
restartDeployment
