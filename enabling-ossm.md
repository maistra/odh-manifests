# Steps to install ODH with OSSM

## Prerequisites

* Openshift cluster with enough karma
* CLI tools
  * `kustomize` v5.0.0+
  * `kubectl`

* Installed operators
  * Kiali
  * Jaeger
  * OSSM
  * OpenData Hub
  
### Check if required operators are installed

```sh
kubectl get operators | awk -v RS= '/kiali/ && /jaeger/ && /servicemesh/ && /opendatahub/ {exit 0} {exit 1}' || echo "Please install all required operators."
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

  createSubscription "kiali-ossm"
  createSubscription "jaeger-product"
  createSubscription "servicemeshoperator"
  createSubscription "opendatahub-operator" "community-operators"
  ```

</details>

## Install Openshift Service Mesh Control Plane

```sh
kustomize build service-mesh | kubectl apply -f -
```

## Setting up Authorizantion Service

```sh
kustomize build auth/cluster | kubectl apply -f -
```

Check if Istio proxy is deployed. Trigger restart of deployment if that's not the case.

```sh
 kubectl get pods -n auth-provider -o yaml | grep -q istio-proxy || kubectl rollout restart deployment --selector=app=auth-service -n auth-provider  
```

Register external authz provider in Service Mesh

```sh
kubectl patch smcp/basic -n istio-system --patch-file auth/mesh/patch-control-plane-external-provider.yaml --type=merge
```

## Setting up Opendatahub Project

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

For convenience, we can create an alias.

```sh
alias kfdef="FORK=$(git remote get-url fork | cut -d':' -f 2 | cut -d'.' -f 1 | uniq | tail -n 1 | cut -d'/' -f 1) CURRENT_BRANCH=$(git symbolic-ref --short HEAD) envsubst < odh-minimal.yaml"
```

### Deployment

```sh
kubectl create ns opendatahub
```

First, add project to Service Mesh and set-up routing.

```sh
kustomize build odh-dashboard/overlays/service-mesh | kubectl apply -f -
```

Then create ODH setup

```sh
kubectl apply -n opendatahub -f - < <(kfdef)  
```
