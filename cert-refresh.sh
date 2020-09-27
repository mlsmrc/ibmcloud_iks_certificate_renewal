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

# export DEBUG=<random_string> to read values from values.sh script
[ ! -z "$DEBUG" ] && source values.sh

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
[ ! -z "$CERT_CRT_PATH" ] && BACKUP_CERT_CRT_PATH=$BACKUP_FOLDER"/"$(basename $CERT_CRT_PATH)
[ ! -z "$CERT_KEY_PATH" ] && BACKUP_CERT_KEY_PATH=$BACKUP_FOLDER"/"$(basename $CERT_KEY_PATH)

# Using this annotation for new/backup secret
ANNOTATION="author=certificate_renewal_agent"

################################ UTILS ################################

#===  FUNCTION  ================================================================
#         NAME:  crnEncode
#  DESCRIPTION:  URL Encoding
# PARAMETER  1:  url
#                The url which is going to be encoded
#       RETURN:  0 for success; 1 otherwise
#===============================================================================
function crnEncode()
{
  local url=$1
  echo ${url} | sed "s/:/%3A/g" | sed "s/\//%2F/g"
}

#===  FUNCTION  ================================================================
#         NAME:  _echo
#  DESCRIPTION:  Redirecting output to $LOG_FILE
# PARAMETER  1:  url
#                The url which is going to be encoded
#       RETURN:  0 for success; 1 otherwise
#===============================================================================
function _echo()
{
  echo $1 >> $LOG_FILE
}

#===  FUNCTION  ================================================================
#         NAME:  isBase64EncodedKubeSecret
#  DESCRIPTION:  Check if a given certificate (named $CRT_FILE_NAME) is Base64
#                encrypted
#         NOTE:  Not more used
#       RETURN:  0 for success; 1 otherwise
#===============================================================================
function isBase64EncodedCrt()
{
  local CRT_FILE_NAME=$1
  echo $CRT_FILE_NAME | grep -q "END CERTIFICATE\|BEGIN CERTIFICATE" && return 1
  return 0
}

#===  FUNCTION  ================================================================
#         NAME:  isBase64EncodedKubeSecret
#  DESCRIPTION:  Check if a given secret (named $SECRET_NAME) is Base64
#                encrypted
#         NOTE:  Not more used
#       RETURN:  0 for success; 1 otherwise
#===============================================================================
function isBase64EncodedKubeSecret()
{
  local SECRET_NAME=$1
  local crt_file_name=$(basename $2)
  kubectl get secret $SECRET_NAME -n $SECRET_NAMESPACE -o json | \
                  jq --arg name $crt_file_name -r '.data[$name]' | \
                  grep -q "END CERTIFICATE\|BEGIN CERTIFICATE" && return 1
  return 0
}

#===  FUNCTION  ================================================================
#         NAME:  checkArgs
#  DESCRIPTION:  Check it all mandatory parameters are not empty
# PARAMETER  1:  ---
#       RETURN:  0 for success; 1 otherwise
#===============================================================================
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
    [ -z "${!var}" ] && _echo "Variable $var is missing" && rc=1
  done

  return $rc
}

################################ Logs ###############################

#===  FUNCTION  ================================================================
#         NAME:  checkLogFile
#  DESCRIPTION:  Check the log file provided as $LOG_FILE. If "/dev/stdout" is
#                selected, it's going to use "/dev/stderr"
# PARAMETER  1:  ---
#       RETURN:  ---
#===============================================================================
function checkLogFile()
{
  [ -z "$LOG_FILE" ] && { LOG_FILE="/dev/stderr"; _echo "LOG_FILE variable not set"; }
  [[ "$LOG_FILE" == "/dev/stdout" ]] && { LOG_FILE="/dev/stderr"; _echo "/dev/stdout is not allowed for logs"; }
  _echo "Using $LOG_FILE for logs"
  _echo ""
}

################################ IAM ################################

#===  FUNCTION  ================================================================
#         NAME:  getIamToken
#  DESCRIPTION:  Giving the IBM Cloud APIKey it produces the IAM token
# PARAMETER  1:  API_KEY
#                it's the IBM Cloud APIkey which has the IBM Cloud Certificate
#                Manager visibility
# PARAMETER  2:  SILENT
#                It's an 0/1 value which allow the printing out of the auth
#                result
#       RETURN:  0 for the success and the IAM token as string; 1 otherwise
#===============================================================================
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

#===  FUNCTION  ================================================================
#         NAME:  ibmCloudLogin
#  DESCRIPTION:  It performs the IBMCloud login using the $CLOUD_REGION region,
#                the resource group $CLOUD_RESOURCE_GROUP and the IAM API Key
#                $CLOUD_API_KEY
# PARAMETER  1:  ---
#       RETURN:  0 for the success; 1 otherwise
#===============================================================================
function ibmCloudLogin()
{
  _echo "IBMCloud login"
  _echo "Region $CLOUD_REGION"
  _echo "Resource group: $CLOUD_RESOURCE_GROUP"
  yes | ibmcloud login --apikey $CLOUD_API_KEY -r $CLOUD_REGION -g $CLOUD_RESOURCE_GROUP
  return $?
}

#===  FUNCTION  ================================================================
#         NAME:  kubeconfigRefresh
#  DESCRIPTION:  It gets the kubeconfig file of the cluster (specified by
#                $CLUSTER_ID) leveraging the 'ibmcloud ks' command.
# PARAMETER  1:  ---
#       RETURN:  0 for the success; 1 otherwise
#===============================================================================
function kubeconfigRefresh()
{
  _echo "Refreshing Cluster '$CLUSTER_ID' token"
  ibmcloud ks cluster config --cluster $CLUSTER_ID
  return $?
}


################################ CM ################################

#===  FUNCTION  ================================================================
#         NAME:  getJsonCertFromCertManager
#  DESCRIPTION:  it gets the certificate (referred by $CERT_CRN) in a json
#                format from IBM Cloud Certificate Manager instance leveraging
#                the IBMCloud Apikey ($API_KEY) for the authentication
# PARAMETER  1:  API_KEY
#                it's the IBM Cloud APIkey which has the IBM Cloud Certificate
#                Manager visibility
# PARAMETER  2:  CERT_CRN
#                The full CRN (Cloud Resource name) of the certificate stored
#                into the IBM Cloud Certificate Manager
#       RETURN:  json which represents all the certificate fields
#===============================================================================
function getJsonCertFromCertManager()
{
  [ $# -ne 2 ] && _echo "usage getJsonCertFromCertManager <api_token> <cert_crn>" && return 1
  local API_KEY=$1
  local CERT_CRN=$2

  token=$(getIamToken ${API_KEY} $YES)
  encodedCrn=$(crnEncode ${CERT_CRN})
  curl --silent -H "Authorization: Bearer $token"  ${API_V2_ENDPOINT}"certificate/"${encodedCrn}
}

#===  FUNCTION  ================================================================
#         NAME:  getJsonCertsFromCertManager
#  DESCRIPTION:  it gets all the certificate in a json format from IBM Cloud
#                Certificate Manager (referred by $CM_FULL_CRN) leveraging the
#                IBMCloud Apikey ($API_KEY) for the authentication
# PARAMETER  1:  API_KEY
#                it's the IBM Cloud APIkey which has the IBM Cloud Certificate
#                Manager visibility
# PARAMETER  2:  CM_FULL_CRN
#                The full CRN (Cloud Resource name) of the IBM Cloud Certificate
#                manager where the certificate you're looking for is stored
#       RETURN:  json which represents all the visible certificates
#===============================================================================
function getJsonCertsFromCertManager()
{
  [ $# -ne 2 ] && _echo "usage getJsonCertsFromCertManager <api_token> <cert_folder_crn>" && return 1
  local API_KEY=$1
  local CM_FULL_CRN=$2

  local token=$(getIamToken ${API_KEY} $YES)
  local encodedCrn=$(crnEncode ${CM_FULL_CRN})
  curl --silent -H "Authorization: Bearer $token" ${API_V3_ENDPOINT}${encodedCrn}"/certificates/"
}

#===  FUNCTION  ================================================================
#         NAME:  getCrnCertFromCertManager
#  DESCRIPTION:  it gets the certificate CRN (Cloud Resource Name) of the
#                certificate (specified by the domain $DOMAIN - actually it's
#                hostname.domainname),from IBM Cloud Certificate Manager
#                (referred by $CM_FULL_CRN) leveraging the IBMCloud Apikey
#                ($API_KEY) for the authentication
#                IBMCloud Apikey ($API_KEY).
# PARAMETER  1:  API_KEY
#                it's the IBM Cloud APIkey which has the IBM Cloud Certificate
#                Manager visibility
# PARAMETER  2:  CM_FULL_CRN
#                The full CRN (Cloud Resource name) of the IBM Cloud Certificate
#                manager where the certificate you're looking for is stored
# PARAMETER  3:  DOMAIN
#                The domain (actually it's hostname.domainname) of releated to
#                the certificate key you're looking for
#       RETURN:  0 the certificate CRN (Cloud Resource name) is found; 1
#                otherwise
#===============================================================================
function getCrnCertFromCertManager()
{
  [ $# -ne 3 ] && _echo "usage getCrnCertFromCertManager <api_token> <cm_crn> <domain>" && return 1
  local API_KEY=$1
  local CM_FULL_CRN=$2
  local DOMAIN=$3

  _echo "Getting Certificate CRN of $DOMAIN"
  jsonCerts=$(getJsonCertsFromCertManager $API_KEY $CM_FULL_CRN)
  [[  "$(echo $jsonCerts | jq .message)" == "Unauthorized" ]] && return 1

  local jsonCert=$(echo $jsonCerts | jq .certificates | jq --arg d $DOMAIN '[ .[] | select(.domains[] | contains ($d))]')

  if [ $(echo $jsonCert | jq length) -eq 1 ]; then
    local id=$(echo $jsonCert | jq -r .[0]._id)
    _echo "CRN Found: $id"
    echo $id
    return 0
  fi

  _echo "Certificate CRN not found"
  return 1
}

#===  FUNCTION  ================================================================
#         NAME:  getValueFileFromCert
#  DESCRIPTION:  Storing certificate (referring to $DOMAIN) field (specified by
#                $VALUE) from IBM Cloud Certificate Manager (referred by
#                $CM_FULL_CRN) into a file (named $FILE_NAME) leveraging the
#                IBMCloud Apikey ($API_KEY)
# PARAMETER  1:  API_KEY
#                it's the IBM Cloud APIkey which has the IBM Cloud Certificate
#                Manager visibility
# PARAMETER  2:  CM_FULL_CRN
#                The full CRN (Cloud Resource name) of the IBM Cloud Certificate
#                manager where the certificate you're looking for is stored
# PARAMETER  3:  DOMAIN
#                The domain (actually it's hostname.domainname) of releated to
#                the certificate key you're looking for
# PARAMETER  4:  VALUE
#                This is the certificate value (json format) which it's going to
#                to be stored into the local file system
# PARAMETER  5:  FILE_NAME
#                File name referring to file system position where the
#                certificate is going to be store
#       RETURN:  0 if the field is correctly stored as file; 1 otherwise
#===============================================================================
function getValueFileFromCert()
{
  [ $# -ne 5 ] && _echo "usage getCertFileFromCert <api_token> <cm_crn> <domain> <value> <file_name>" && return 1
  local API_KEY=$1
  local CM_FULL_CRN=$2
  local DOMAIN=$3
  local VALUE=$4
  local FILE_NAME=$5

  # Get Certificate CRN
  local CERT_CRN=$(getCrnCertFromCertManager $API_KEY $CM_FULL_CRN $DOMAIN)
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
  [[ "$(cat $FILE_NAME)" == "null" ]] && _echo "Certificate Key not exists" && rm -rf $FILE_NAME && return 1

  _echo "Done"
}


#===  FUNCTION  ================================================================
#         NAME:  getCrtFileFromCert
#  DESCRIPTION:  Storing certificate (referring to $DOMAIN) from IBM Cloud
#                Certificate Manager (referred by $CM_FULL_CRN) into a file
#                (named $FILE_NAME) leveraging the IBMCloud Apikey ($API_KEY)
# PARAMETER  1:  API_KEY
#                it's the IBM Cloud APIkey which has the IBM Cloud Certificate
#                Manager visibility
# PARAMETER  2:  CM_FULL_CRN
#                The full CRN (Cloud Resource name) of the IBM Cloud Certificate
#                manager where the certificate you're looking for is stored
# PARAMETER  3:  DOMAIN
#                The domain (actually it's hostname.domainname) of releated to
#                the certificate key you're looking for
# PARAMETER  4:  FILE_NAME
#                File name referring to file system position where the
#                certificate is going to be store
#       RETURN:  0 if the certificate ".data.content" field is stored as file
#                (named $FILE_NAME) correctly; 1 otherwise
#===============================================================================
function getCrtFileFromCert()
{
  local API_KEY=$1
  local CM_FULL_CRN=$2
  local DOMAIN=$3
  local FILE_NAME=$4
  getValueFileFromCert $API_KEY $CM_FULL_CRN $DOMAIN ".data.content" $FILE_NAME
  return $?
}

#===  FUNCTION  ================================================================
#         NAME:  getKeyFileFromCert
#  DESCRIPTION:  Storing certificate key (referring to $DOMAIN) from IBM Cloud
#                Certificate Manager (referred by $CM_FULL_CRN) into a file
#                (named $FILE_NAME) leveraging the IBMCloud Apikey ($API_KEY)
# PARAMETER  1:  API_KEY
#                it's the IBM Cloud APIkey which has the IBM Cloud Certificate
#                Manager visibility
# PARAMETER  2:  CM_FULL_CRN
#                The full CRN (Cloud Resource name) of the IBM Cloud Certificate
#                manager where the certificate key you're looking for is stored
# PARAMETER  3:  DOMAIN
#                The domain (actually it's hostname.domainname) of releated to
#                the certificate key you're looking for
# PARAMETER  4:  FILE_NAME
#                File name referring to file system position where the
#                certificate key is going to be store
#       RETURN:  0 if the certificate ".data.content" field is stored as file
#                (named $FILE_NAME) correctly; 1 otherwise
#===============================================================================
function getKeyFileFromCert()
{
  local API_KEY=$1
  local CM_FULL_CRN=$2
  local DOMAIN=$3
  local FILE_NAME=$4
  getValueFileFromCert $API_KEY $CM_FULL_CRN $DOMAIN ".data.priv_key" $FILE_NAME
  return $?
}

################################ K8s ################################

#===  FUNCTION  ================================================================
#         NAME:  secretExists
#  DESCRIPTION:  Check if the Kubernetes secret $SECRET_NAME exists in
#                Kubernetes namespace $SECRET_NAMESPACE
# PARAMETER  1:  ---
#       RETURN: 0 if secret exists; 1 otherwise
#===============================================================================
function secretExists()
{
  _echo "Check if secret '$SECRET_NAME' exists"
  kubectl get secret $SECRET_NAME -n $SECRET_NAMESPACE &>1 >> $LOG_FILE
  local rc=$?

  [ $rc -eq 0 ] && _echo "Secret found" \
                || _echo "Secret not exists"

  return $rc
}

#===  FUNCTION  ================================================================
#         NAME:  namespaceExists
#  DESCRIPTION:  Check if the Kubernetes namespace $SECRET_NAMESPACE exists
# PARAMETER  1:  ---
#       RETURN: 0 if namespace exists; 1 otherwise
#===============================================================================
function namespaceExists()
{
  _echo "Check if provided namespace exists $SECRET_NAMESPACE"
  kubectl get ns $SECRET_NAMESPACE &>1 >> $LOG_FILE
  local rc=$?

  [ $rc -eq 0 ] && _echo "Namespace found" \
                || _echo "Namespace not exists"

  return $rc
}

#===  FUNCTION  ================================================================
#         NAME:  createKubeSecret
#  DESCRIPTION:  Create a new Kubernetes secret - named $SECRET_NAME on namespace
#                $SECRET_NAMESPACE based on crt/key ($CERT_CRT_PATH /
#                $CERT_KEY_PATH file stored on file system
# PARAMETER  1:  ---
#===============================================================================
function createKubeSecret()
{
  _echo "Creating Kubernetes secret '$SECRET_NAME' on namespace '$SECRET_NAMESPACE' based on $CERT_CRT_PATH/$CERT_KEY_PATH"

  kubectl create secret generic $SECRET_NAME -n $SECRET_NAMESPACE --from-file=$(basename $CERT_CRT_PATH)=$CERT_CRT_PATH \
                                                                  --from-file=$(basename $CERT_KEY_PATH)=$CERT_KEY_PATH

  annotateKubeSecret $SECRET_NAME
}

#===  FUNCTION  ================================================================
#         NAME:  annotateKubeSecret
#  DESCRIPTION:  Annotate the generated Kubernetes secret
# PARAMETER  1:  secret_name
#                the secret which must to be annotated
#===============================================================================
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

#===  FUNCTION  ================================================================
#         NAME:  backupKubeSecret
#  DESCRIPTION:  Delete the old backup if exists. Backupping the current
#                Kubernetes secret - specified by ${SECRET_NAME} - creating a
#                new one named ${SECRET_NAME}-backup.
#                Annotate the secret with annotateKubeSecret function, using the
#                label $secret_name_backup
# PARAMETER  1:  ---
#===============================================================================
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

#===  FUNCTION  ================================================================
#         NAME:  restartDeployment
#  DESCRIPTION:  Forcing the kubernetes deployment - specified by
#                $KUBE_DEPLOY_NAME - restart. Then it waits about the deployment
#                rollout status
# PARAMETER  1:  ---
#===============================================================================
function restartDeployment()
{
  _echo "Restarting deployment $KUBE_DEPLOY_NAME"
  kubectl rollout restart deployment $KUBE_DEPLOY_NAME -n $SECRET_NAMESPACE

  _echo "Getting deployment $KUBE_DEPLOY_NAME rollout status"
  kubectl rollout status deployment $KUBE_DEPLOY_NAME -n $SECRET_NAMESPACE
}

#===  FUNCTION  ================================================================
#         NAME:  deleteOldKubeSecret
#  DESCRIPTION:  Delete the old Kubernetes secret named $SECRET_NAME
# PARAMETER  1:  ---
#===============================================================================
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
