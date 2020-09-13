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
LOG_FILE="/var/log/certificate-refresh.log"

################################ UTILS ################################

function crnEncode()
{
  url=$1
  echo ${url} | sed "s/:/%3A/g" | sed "s/\//%2F/g"
}
function _echo() { echo $1 1>&2; echo $1 >> $LOG_FILE; }

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

  # local jsonCert=$(jq .certificates | jq --arg d $DOMAIN '[ .[] | select(.domains[] | contains ($d))]')
  i=0
  while [ true ]; do
    jsonCert=$(echo $jsonCerts | jq .certificates[$i])

    domains=$(echo $jsonCert | jq .domains)


    [[ "$domains" == "null" ]] && break

    echo $domains | grep -q "$DOMAIN"
    [ $? -eq 0 ] && { _id=$(echo $jsonCert | jq ._id | tr -d "\""); _echo "Found $_id"; echo $_id; return 0; }
    i=$((i+1))
  done

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

#######################################################
# Main
#######################################################

# Validate api token
getIamToken $CLOUD_API_KEY $NO || RC=1
if [ $RC -ne 1 ]; then
  getCrtFileFromCert $CLOUD_API_KEY $CM_FULL_CRN $HOSTNAME_DOMAINAME $CERT_CRT_PATH || RC=2
  getKeyFileFromCert $CLOUD_API_KEY $CM_FULL_CRN $HOSTNAME_DOMAINAME $CERT_KEY_PATH || RC=3
fi

_echo "Certificate download exit code: $RC"
exit $RC
