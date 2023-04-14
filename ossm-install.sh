#!/bin/bash

# Installing ODH with OSSM

## Prerequisites

# Required CLI tools
required_cli_tools=(kustomize kubectl envsubst openssl jq yq operator-sdk)
for tool in "${required_cli_tools[@]}"
do
    if ! command -v $tool &> /dev/null
    then
        echo "ERROR: $tool is required but not installed"
        exit 1
    fi
done

# Required Operators
required_operators=(kiali jaeger servicemesh opendatahub authorino)
if ! kubectl get operators | awk -v RS= '/kiali/ && /jaeger/ && /servicemesh/ && /opendatahub/ && /authorino/ {exit 0} {exit 1}' &> /dev/null
then
    echo "Please install all required operators."
    exit 1
fi

# create istio-system ns, install smcp

echo "Install Openshift Service Mesh Control Plane"
createSMCP() {
until kubectl get crd servicemeshcontrolplanes.maistra.io  >/dev/null 2>&1; do  echo 'Waiting for smcp CRD to appear...'; sleep 1; done
kustomize build service-mesh/control-plane/base | kubectl apply -f -
sleep 4 # to prevent kubectl wait from failing
kubectl wait --for condition=Ready smcp/basic --timeout 300s -n istio-system
}
createSMCP

## Create Kubeflow Definition
# TODO: revise this section to ideally no longer use an alias. perhaps link to a gist??? not sure yet

cat <<'EOF' > odh-minimal.yaml
apiVersion: kfdef.apps.kubeflow.org/v1
kind: KfDef
metadata:
 name: odh-minimal
spec:
 applications:
 - kustomizeConfig:
     repoRef:
       name: manifests
       path: odh-common
   name: odh-common
 - kustomizeConfig:
     repoRef:
       name: manifests
       path: odh-dashboard
   name: odh-dashboard
 - kustomizeConfig:
     repoRef:
       name: manifests
       path: odh-notebook-controller
   name: odh-notebook-controller
 - kustomizeConfig:
     repoRef:
       name: manifests
       path: notebook-images
   name: notebook-images
 repos:
 - name: manifests
   uri: https://github.com/$FORK/odh-manifests/tarball/$CURRENT_BRANCH
 version: $CURRENT_BRANCH
EOF


# For convenience, we can create an alias (but you have to have `git remote` named `fork` to make it work):

alias kfdef="FORK=$(git remote get-url fork | cut -d':' -f 2 | cut -d'.' -f 1 | uniq | tail -n 1 | cut -d'/' -f 1) CURRENT_BRANCH=$(git symbolic-ref --short HEAD) envsubst < odh-minimal.yaml"

echo "Create namespace for ODH"

export ODH_NS=opendatahub
kubectl create ns $ODH_NS

echo "Add service mesh routing for ODH."

kustomize build odh-dashboard/overlays/service-mesh | kubectl apply -f -

echo "Install ODH by creating KfDef"

createODH() {
kubectl apply -n $ODH_NS -f - < <(kfdef)  
until kubectl get deployments -n $ODH_NS  >/dev/null 2>&1; do  echo 'Waiting for ODH deployments to appear...'; sleep 1; done
kubectl wait --for condition=available deployment --all --timeout 360s -n $ODH_NS
}
createODH

echo "Ensure ODH pods have istio-proxy injected - if not, restart pods."

kubectl get pods -n $ODH_NS -o yaml | grep -q istio-proxy || kubectl get deployments -o name -n $ODH_NS | xargs -I {} kubectl rollout restart {} -n $ODH_NS

echo "Patch ODHDashboardConfig to enable ServiceMesh." 

kubectl patch odhdashboardconfig odh-dashboard-config -n $ODH_NS --patch-file odh-dashboard/overlays/service-mesh/patch-dashboard-config.yaml --type=merge

# Auth service section

echo "Create requisite environment variables for deploying authorization service"

export AUTH_NS=auth-provider
export CLIENT_SECRET=$(openssl rand -base64 32)
export CLIENT_HMAC=$(openssl rand -base64 32)
export ODH_ROUTE=$(kubectl get route --all-namespaces -l maistra.io/gateway-name=odh-gateway -o yaml | yq '.items[].spec.host')
export OAUTH_ROUTE=$(kubectl get route --all-namespaces -l app=oauth-openshift -o yaml | yq '.items[].spec.host')
endpoint=$(kubectl -n default run oidc-config --attach --rm --restart=Never -q --image=curlimages/curl -- https://kubernetes.default.svc/.well-known/oauth-authorization-server -sS -k)
export TOKEN_ENDPOINT=$(echo $endpoint | jq .token_endpoint)
export AUTH_ENDPOINT=$(echo $endpoint | jq .authorization_endpoint)

echo $CLIENT_SECRET

echo "Create authorization service."

createAuthProvider() {
kustomize build service-mesh/auth/cluster | envsubst | kubectl apply -f -
until kubectl get deployments -n $AUTH_NS  >/dev/null 2>&1; do  echo 'Waiting for AUTH_NS deployments to appear...'; sleep 1; done
kubectl wait --for condition=available deployment --all --timeout 360s -n $AUTH_NS
}
createAuthProvider

echo "Ensure auth provider has istio-proxy injected."

kubectl get pods -n $AUTH_NS -o yaml | grep -q istio-proxy || kubectl rollout restart deployment authorino -n $AUTH_NS

echo "Mount OAuth2 secrets to Istio gateways"

kubectl patch smcp/basic -n istio-system --patch-file service-mesh/auth/mesh/patch-control-plane-mount-oauth2-secrets.yaml --type=merge

echo "Ensure Oauth2 secret present in ingress-gateway"

sleep(10) # hardcoded wait for new pod to spawn.
kubectl wait pods -l app=istio-ingressgateway --for condition=ready -n istio-system
kubectl exec $(kubectl get pods -n istio-system -l app=istio-ingressgateway  -o jsonpath='{.items[*].metadata.name}') -n istio-system -c istio-proxy -- ls -al /etc/istio/odh-oauth2
# todo: add check that greps output for failure.

echo "Register external authz provider in Service Mesh control plane"

kubectl patch smcp/basic -n istio-system --patch-file service-mesh/auth/mesh/patch-control-plane-external-provider.yaml --type=merge

sleep(15) # temp? hardcoded sleep to wait for smcp to sync ext auth config.
xdg-open https://$ODH_ROUTE > /dev/null 2>&1 &    