# Steps to install ODH with OSSM

## Prerequisites

* Openshift cluster with enough karma (make sure to log in :))
* CLI tools
  * `kustomize` 
  * `kubectl`
  * (until operator changes are merged) `operator-sdk` v1.24.1

* Installed operators
  * Kiali
  * Jaeger
  * OSSM
  * OpenDataHub
  * Authorino
  
### Check if required operators are installed

```sh
kubectl get operators | awk -v RS= '/kiali/ && /jaeger/ && /servicemesh/ && /opendatahub/ && /authorino/ {exit 0} {exit 1}' || echo "Please install all required operators."
```

Install required operators

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
  # createSubscription "opendatahub-operator" "community-operators"
  # temp, until operator changes are merged.
  operator-sdk run bundle quay.io/cgarriso/opendatahub-operator-bundle:dev-0.0.2 --namespace openshift-operators --timeout 5m0s
  createSubscription "authorino-operator" "community-operators" "alpha"
  ```

Note that you may need to go into the `Installed Operators` tab in the console to manually finalize the install of the authorino operator.

## Setting up Open Data Hub Project

### Create Kubeflow Definition

```sh
cat <<'EOF' > odh-minimal.ign.yaml
apiVersion: kfdef.apps.kubeflow.org/v1
kind: KfDef
metadata:
 name: odh-minimal
spec:
 applications:
 - kustomizeConfig:
      parameters:
        - name: namespace
          value: istio-system
      repoRef:
        name: manifests
        path: service-mesh/control-plane
   name: control-plane
 - kustomizeConfig:
      overlays:
        - service-mesh
      repoRef:
        name: manifests
        path: odh-common
   name: odh-common
 - kustomizeConfig:
      overlays:
        - service-mesh
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
        path: odh-project-controller
   name: odh-project-controller
 - kustomizeConfig:
      repoRef:
        name: manifests
        path: notebook-images
   name: notebook-images
 - kustomizeConfig:
      parameters:
        - name: namespace
          value: auth-provider
      repoRef:
        name: manifests
        path: service-mesh/authorino
   name: authorino
 repos:
 - name: manifests
   uri: https://github.com/maistra/odh-manifests/tarball/service-mesh-integration
 version: service-mesh-integration
EOF
```

Let's start with the namespaces

```sh
export ODH_NS=opendatahub
kubectl create ns $ODH_NS
kubectl create ns auth-provider
kubectl create ns istio-system
```

Now create the KfDef resource in the opendatahub namespace. This will also create the requisite service mesh and authorino resources in their respective namespaces.

```sh
kubectl apply -n $ODH_NS -f odh-minimal.yaml
kubectl wait --for condition=available kfdef --all --timeout 360s -n $ODH_NS
kubectl wait --for condition=ready pod --all --timeout 360s -n $ODH_NS
```

Check if Istio proxy is deployed. Trigger restart of all deployments if that's not the case.

```sh
kubectl get pods -n $ODH_NS -o yaml | grep -q istio-proxy || kubectl get deployments -o name -n $ODH_NS | xargs -I {} kubectl rollout restart {} -n $ODH_NS   
```


Now you can open Open Data Hub dashboard in the browser:

```sh
export ODH_ROUTE=$(kubectl get route --all-namespaces -l maistra.io/gateway-name=odh-gateway -o yaml | yq '.items[].spec.host')

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

In case of the latter check if the token is the same everywhere by comparing output of the following commands:

```sh
kubectl get oauthclient.oauth.openshift.io odh
kubectl exec $(kubectl get pods -n istio-system -l app=istio-ingressgateway  -o jsonpath='{.items[*].metadata.name}') -n istio-system -c istio-proxy -- cat /etc/istio/odh-oauth2/token-secret.yaml
kubectl get configmap istio-odh-oauth2 -n istio-system -o yaml
```

It might be that ingressgateway pod is out of sync, so restarting it might help:

```sh
kubectl rollout restart deployment -n istio-system istio-ingressgateway  
```
