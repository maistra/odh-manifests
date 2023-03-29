# Steps to install ODH with OSSM

## Prerequisites

* Openshift cluster with enough karma (make sure to log in :))
* CLI tools
  * `kustomize` v5.0.0+
  * `kubectl`
  * `envsubst`
  * `openssl`
  * `jq` and `yq`

* Installed operators
  * Kiali
  * Jaeger
  * OSSM
  * OpenData Hub
  * Authorino
  
### Check if required operators are installed

```sh
kubectl get operators | awk -v RS= '/kiali/ && /jaeger/ && /servicemesh/ && /opendatahub/ && /authorino/ {exit 0} {exit 1}' || echo "Please install all required operators."
```

<details>
  <summary>
    Install required operators
  </summary>

  ```sh
  createSubscription() {
    local name=$1
    local source=${2:-"redhat-operators"}
    local channel=${3:-"stable"}

    echo  "Create Subscription resource for $name"
    eval "kubectl apply -f - <<EOF
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
    name: $name
    namespace: openshift-operators
  spec:
    channel: $channel
    installPlanApproval: Automatic
    name: $name
    source: $source
    sourceNamespace: openshift-marketplace
  EOF"    
  }
  ```
  
  ```sh
  createSubscription "kiali-ossm"
  createSubscription "jaeger-product"
  createSubscription "servicemeshoperator"
  createSubscription "opendatahub-operator" "community-operators"
  createSubscription "authorino-operator" "community-operators" "alpha"
  ```

</details>

## Install Openshift Service Mesh Control Plane

```sh
until kubectl get crd servicemeshcontrolplanes.maistra.io  >/dev/null 2>&1; do  echo 'Waiting for smcp CRD to appear...'; sleep 1; done
kustomize build service-mesh | kubectl apply -f -
sleep 4 # to prevent kubectl wait from failing
kubectl wait --for condition=Ready smcp/basic --timeout 300s -n istio-system
```

## Setting up Open Data Hub Project

### Create Kubeflow Definition

```sh
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
```

For convenience, we can create an alias (but you have to have `git remote` named `fork` to make it working):

```sh
alias kfdef="FORK=$(git remote get-url fork | cut -d':' -f 2 | cut -d'.' -f 1 | uniq | tail -n 1 | cut -d'/' -f 1) CURRENT_BRANCH=$(git symbolic-ref --short HEAD) envsubst < odh-minimal.yaml"
```

### Deployment

Let's start with the namespace

```sh
export ODH_NS=opendatahub
kubectl create ns $ODH_NS
```

to add the project to Service Mesh and set up the routing:

```sh
kustomize build odh-dashboard/overlays/service-mesh | kubectl apply -f -
```

and finally to create ODH project:

```sh
kubectl apply -n $ODH_NS -f - < <(kfdef)  
until kubectl get deployments -n $ODH_NS  >/dev/null 2>&1; do  echo 'Waiting for ODH deployments to appear...'; sleep 1; done
kubectl wait --for condition=available deployment --all --timeout 360s -n $ODH_NS
```

Check if Istio proxy is deployed. Trigger restart of all deployments if that's not the case.

```sh
kubectl get pods -n $ODH_NS -o yaml | grep -q istio-proxy || kubectl get deployments -o name -n $ODH_NS | xargs -I {} kubectl rollout restart {} -n $ODH_NS   
```

## Setting up Authorizantion Service

```sh
export AUTH_NS=auth-provider
export CLIENT_SECRET=$(openssl rand -base64 32)
export CLIENT_HMAC=$(openssl rand -base64 32)
export ODH_ROUTE=$(kubectl get route --all-namespaces -l maistra.io/gateway-name=odh-gateway -o yaml | yq '.items[].spec.host')
export OAUTH_ROUTE=$(kubectl get route --all-namespaces -l app=oauth-openshift -o yaml | yq '.items[].spec.host')
endpoint=$(kubectl -n default run oidc-config --attach --rm --restart=Never -q --image=curlimages/curl -- https://kubernetes.default.svc/.well-known/oauth-authorization-server -sS -k)
export TOKEN_ENDPOINT=$(echo $endpoint | jq .token_endpoint)
export AUTH_ENDPOINT=$(echo $endpoint | jq .authorization_endpoint)
kustomize build auth/cluster | envsubst | kubectl apply -f - 
until kubectl get deployments -n $AUTH_NS  >/dev/null 2>&1; do  echo 'Waiting for AUTH_NS deployments to appear...'; sleep 1; done
kubectl wait --for condition=available deployment --all --timeout 360s -n $AUTH_NS
```

Check if Istio proxy is deployed. Trigger restart of deployment if that's not the case.

```sh
kubectl get pods -n $AUTH_NS -o yaml | grep -q istio-proxy || kubectl rollout restart deployment authorino -n $AUTH_NS
```

Mount OAuth2 secrets to Istio gateways

```sh
kubectl patch smcp/basic -n istio-system --patch-file auth/mesh/patch-control-plane-mount-oauth2-secrets.yaml --type=merge
```

You can validate if the secrets are mounted by executing (it might take some time for pod to show up with updated config):

```sh
kubectl wait pods -l app=istio-ingressgateway --for condition=ready -n istio-system
kubectl exec $(kubectl get pods -n istio-system -l app=istio-ingressgateway  -o jsonpath='{.items[*].metadata.name}') -n istio-system -c istio-proxy -- ls -al /etc/istio/odh-oauth2
```

Register [external authz provider](https://istio.io/latest/docs/tasks/security/authorization/authz-custom/) in Service Mesh:

```sh
kubectl patch smcp/basic -n istio-system --patch-file auth/mesh/patch-control-plane-external-provider.yaml --type=merge
```

Now you can open Open Data Hub dashboard in the browser:

```sh
xdg-open https://$ODH_ROUTE > /dev/null 2>&1 &    
```

## Troubleshooting

### `OAuth flow failed`

If you see a message `OAuth flow failed` while trying to access the web app please check logs of `openshift-authentication` pod(s), this can fail for several reasons, but the most frequently I seen:

```sh
kubectl logs $(kubectl get pod -l app=oauth-openshift -n openshift-authentication -o name) -n openshift-authentication  
```

* wrong redirect URL
* mismatching secret between what OAuth client has defined and what is stored in the ConfigMap (that yields an error of unauthenticated client `E0328 18:39:56.277217       1 access.go:177] osin: error=unauthorized_client, internal_error=<nil> get_client=client check failed, client_id=odh`)

In case of the latter check if the token is the same everywhere, but comparing output of the following commands:

```sh
kubectl get oauthclient.oauth.openshift.io odh
kubectl exec $(kubectl get pods -n istio-system -l app=istio-ingressgateway  -o jsonpath='{.items[*].metadata.name}') -n istio-system -c istio-proxy -- cat /etc/istio/odh-oauth2/token-secret.yaml
kubectl get configmap istio-odh-oauth2 -n istio-system -o yaml
```

It might be that ingressgateway pod is out of sync, so restarting it might help:

```sh
kubectl rollout restart deployment -n istio-system istio-ingressgateway  
```
