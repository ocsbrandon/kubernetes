#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Generates pod and secret to deploy origin against configured Kubernetes provider

set -o errexit
set -o nounset
set -o pipefail

ORIGIN=$(dirname "${BASH_SOURCE}")
KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..
source "${KUBE_ROOT}/cluster/kubectl.sh" > /dev/null 2>&1
PUB_KUBE=https://10.0.0.2:443
PUB_MASTER=https://10.0.0.2:443

# Check all prerequisites are on the path
HAVE_JQ=$(which jq)
if [[ -z ${HAVE_JQ} ]]; then
 echo "Please install jq"
 exit 1
fi

HAVE_BASE64=$(which base64)
if [[ -z ${HAVE_BASE64} ]]; then
 echo "Please install base64"
 exit 1
fi

# Detect the OS name so that we know the option to disable line wrapping in base64
case "$(uname -s)" in
    Darwin)
	BASE64_NOWRAP_OPT=--break=0
	;;
    Linux)
	BASE64_NOWRAP_OPT=--wrap=0
	;;
    *)
	echo "Unsupported host OS.  Must be Linux or Mac OS X." >&2
	exit 1
	;;
esac

# Capture information about your kubernetes cluster
TEMPLATE="--template=\"{{ index . \"current-context\" }}\""
CURRENT_CONTEXT=$( "${kubectl}" "${config[@]:+${config[@]}}" config view -o template "${TEMPLATE}" )

TEMPLATE="--template=\"{{ index . \"contexts\" ${CURRENT_CONTEXT} \"cluster\" }}\""
CURRENT_CLUSTER=$( "${kubectl}" "${config[@]:+${config[@]}}" config view -o template "${TEMPLATE}" )

TEMPLATE="--template=\"{{ index . \"contexts\" ${CURRENT_CONTEXT} \"user\" }}\""
CURRENT_USER=$( "${kubectl}" "${config[@]:+${config[@]}}" config view -o template "${TEMPLATE}" )

TEMPLATE="--template={{ index . \"clusters\" ${CURRENT_CLUSTER} \"certificate-authority\" }}"
CERTIFICATE_AUTHORITY=$( "${kubectl}" "${config[@]:+${config[@]}}" config view -o template "${TEMPLATE}" )

TEMPLATE="--template={{ index . \"clusters\" ${CURRENT_CLUSTER} \"server\" }}"
KUBE_MASTER=$( "${kubectl}" "${config[@]:+${config[@]}}" config view -o template "${TEMPLATE}" )

TEMPLATE="--template={{ index . \"users\" ${CURRENT_USER} \"auth-path\" }}"
AUTH_PATH=$( "${kubectl}" "${config[@]:+${config[@]}}" config view -o template "${TEMPLATE}" )

# Build an auth_path file to embed as a secret
AUTH_PATH_DATA=$(cat ${AUTH_PATH} )
KUBE_USER=$( echo ${AUTH_PATH_DATA} | jq '.User' )
KUBE_PASSWORD=$( echo ${AUTH_PATH_DATA} | jq '.Password' )
KUBE_CERT_FILE=$( echo ${AUTH_PATH_DATA} | jq '.CertFile' )
KUBE_KEY_FILE=$( echo ${AUTH_PATH_DATA} | jq '.KeyFile' )

cat <<EOF >"${ORIGIN}/origin-auth-path"
{
  "User": ${KUBE_USER},
  "Password": ${KUBE_PASSWORD},
  "CAFile": "/etc/secret-volume/kube-ca",
  "CertFile": "/etc/secret-volume/kube-cert",
  "KeyFile": "/etc/secret-volume/kube-key"
}
EOF

# Collect all the secrets and encode as base64
ORIGIN_KUBECONFIG_DATA=$( cat ${ORIGIN}/origin-kubeconfig.yaml | sed -e "s#@KUBERNETES_MASTER@#${KUBE_MASTER}#g" | base64 ${BASE64_NOWRAP_OPT})
ORIGIN_CERTIFICATE_AUTHORITY_DATA=$(cat ${CERTIFICATE_AUTHORITY} | base64 ${BASE64_NOWRAP_OPT})
ORIGIN_AUTH_PATH_DATA=$(cat ${ORIGIN}/origin-auth-path | base64 ${BASE64_NOWRAP_OPT})
ORIGIN_CERT_FILE=$( cat ${KUBE_CERT_FILE//\"/} | base64 ${BASE64_NOWRAP_OPT})
ORIGIN_KEY_FILE=$( cat ${KUBE_KEY_FILE//\"/}  | base64 ${BASE64_NOWRAP_OPT})

cat <<EOF >"${ORIGIN}/secret.json"
{
  "apiVersion": "v1beta2",  
  "kind": "Secret",
  "id": "kubernetes-secret",
  "data": {
    "kubeconfig": "${ORIGIN_KUBECONFIG_DATA}",
    "kube-ca": "${ORIGIN_CERTIFICATE_AUTHORITY_DATA}",
    "kube-auth-path": "${ORIGIN_AUTH_PATH_DATA}",
    "kube-cert": "${ORIGIN_CERT_FILE}",
    "kube-key": "${ORIGIN_KEY_FILE}"
  }
}
EOF

echo "Generated Kubernetes Secret file: ${ORIGIN}/secret.json"

# Generate an OpenShift Origin pod
# TODO: In future, move this to a replication controller when we are not running etcd in container

cat <<EOF >"${ORIGIN}/pod.json"
{
  "apiVersion": "v1beta1",
  "id": "openshift",
  "kind": "Pod",   
  "labels": {
    "name": "origin"
  }, 
  "desiredState": {
    "manifest": {
      "containers": [
      {
        "command": [
          "start",
          "master",
          "--kubernetes=${KUBE_MASTER}",
          "--kubeconfig=/etc/secret-volume/kubeconfig",
          "--public-kubernetes=${PUB_KUBE}",
          "--public-master=${PUB_MASTER}",
        ],
        "image": "openshift/origin:latest",
        "imagePullPolicy": "PullIfNotPresent",
        "name": "origin",
        "ports": [
        {
          "name": "https-api",
          "containerPort": 8443,
          "hostPort": 8443,          
        },
        { 
          "name": "https-ui",
          "containerPort": 8444,
          "hostPort": 8444,
        }                        
        ],
        "volumeMounts": [
        {
          "mountPath": "/etc/secret-volume",
          "name": "secret-volume",
          "readOnly": true
        }
        ]
      }
      ],
      "restartPolicy": {
        "never": {}
      },
      "version": "v1beta2",
      "volumes": [
      {
        "name": "secret-volume",
        "source": {
          "secret": {
            "target": {
              "kind": "Secret",
              "name": "kubernetes-secret",
              "namespace": "default"
            }
          }
        }
      }
      ]
    }
  }
}
EOF

echo "Generated Kubernetes Pod file: ${ORIGIN}/pod.json"

cat <<EOF >"${ORIGIN}/api-service.json"
{
  "apiVersion": "v1beta1",  
  "kind": "Service",
  "id": "origin-api",
  "port": 8443,
  "containerPort": 8443,
  "selector": { "name": "origin" },
}
EOF

echo "Generated Kubernetes Service file: ${ORIGIN}/api-service.json"

cat <<EOF >"${ORIGIN}/ui-service.json"
{
  "apiVersion": "v1beta1",  
  "kind": "Service",
  "id": "origin-ui",
  "port": 8444,
  "containerPort": 8444,
  "selector": { "name": "origin" },
}
EOF

echo "Generated Kubernetes Service file: ${ORIGIN}/ui-service.json"




