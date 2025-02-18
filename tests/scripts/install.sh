#!/bin/bash

echo "Installing kfDef from test directory"
KFDEF_FILENAME=odh-core.yaml

set -x
## Install the opendatahub-operator
pushd ~/peak
retry=5
if ! [ -z "${SKIP_OPERATOR_INSTALL}" ]; then
    ## SKIP_OPERATOR_INSTALL is used in the opendatahub-operator repo
    ## because openshift-ci will install the operator for us
    echo "Relying on odh operator installed by openshift-ci"
    ./setup.sh -t ~/peak/operatorsetup 2>&1
else
  echo "Installing operator from community marketplace"
  while [[ $retry -gt 0 ]]; do
    ./setup.sh -o ~/peak/operatorsetup 2>&1
    if [ $? -eq 0 ]; then
      retry=-1
    else
      echo "Trying restart of marketplace community operator pod"
      oc delete pod -n openshift-marketplace $(oc get pod -n openshift-marketplace -l marketplace.operatorSource=community-operators -o jsonpath="{$.items[*].metadata.name}")
      sleep 3m
    fi  
    retry=$(( retry - 1))
    sleep 1m
  done
fi

# Update Install Plan of opendatahub-operator to Automatic. It is set to manual if deployed in openshift-ci
oc patch installplan $(oc get installplan -l operators.coreos.com/opendatahub-operator.openshift-operators -n openshift-operators -o jsonpath="{$.items[*].metadata.name}") \
   --namespace openshift-operators \
    --type merge \
    --patch '{"spec":{"approval":"Automatic"}}'

# Install OpenShift Pipelines operator irrespective of SKIP_OPERATOR_INSTALL value
echo "Installing OpenShift Pipelines operator"
retry=5
while [[ $retry -gt 0 ]]; do
  ./setup.sh -o ~/peak/pipelines-op-setup 2>&1
  if [ $? -eq 0 ]; then
    retry=-1
  else
    echo "Trying restart of marketplace community operator pod"
    oc delete pod -n openshift-marketplace $(oc get pod -n openshift-marketplace -l marketplace.operatorSource=community-operators -o jsonpath="{$.items[*].metadata.name}")
    sleep 3m
  fi
  retry=$(( retry - 1))
  sleep 1m
done

popd
## Install CodFlare Operator
echo "Installing CodeFlare operator"
oc new-project codeflare-operator-system
oc apply -f $HOME/peak/operator-tests/odh-manifests/resources/codeflare-stack/codeflare-subscription.yaml
oc apply -f $HOME/peak/operator-tests/odh-manifests/resources/codeflare-stack/codeflare-operator-system-dependencies.yaml
sleep 15
# We need to manually approve the install plan for the CodeFlare operator as we want to use a tagged version of the operator
oc patch installplan $(oc get installplans -n codeflare-operator-system -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="codeflare-operator")].metadata.name}') -n codeflare-operator-system --type merge -p '{"spec":{"approved":true}}'
## Grabbing and applying the patch in the PR we are testing
pushd ~/src/odh-manifests
if [ -z "$PULL_NUMBER" ]; then
  echo "No pull number, assuming nightly run"
else
  curl -O -L https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PULL_NUMBER}.patch
  echo "Applying followng patch:"
  cat ${PULL_NUMBER}.patch > ${ARTIFACT_DIR}/github-pr-${PULL_NUMBER}.patch
  git apply ${PULL_NUMBER}.patch
fi
popd
## Point manifests repo uri in the KFDEF to the manifests in the PR
pushd ~/kfdef
if [ -z "$PULL_NUMBER" ]; then
  echo "No pull number, not modifying ${KFDEF_FILENAME}"
else
  if [ $REPO_NAME == "odh-manifests" ]; then
    echo "Setting manifests in kfctl_openshift to use pull number: $PULL_NUMBER"
    sed -i "s#uri: https://github.com/opendatahub-io/odh-manifests/tarball/master#uri: https://api.github.com/repos/opendatahub-io/odh-manifests/tarball/pull/${PULL_NUMBER}/head#" ./${KFDEF_FILENAME}
  fi
fi

if [ -z "${OPENSHIFT_TESTUSER_NAME}" ] || [ -z "${OPENSHIFT_TESTUSER_PASS}" ]; then
  OAUTH_PATCH_TEXT="$(cat $HOME/peak/operator-tests/odh-manifests/resources/oauth-patch.htpasswd.json)"
  echo "Creating HTPASSWD OAuth provider"
  oc apply -f $HOME/peak/operator-tests/odh-manifests/resources/htpasswd.secret.yaml

  # Test if any oauth identityProviders exists. If not, initialize the identityProvider list
  if ! oc get oauth cluster -o json | jq -e '.spec.identityProviders' ; then
    echo 'No oauth identityProvider exists. Initializing oauth .spec.identityProviders = []'
    oc patch oauth cluster --type json -p '[{"op": "add", "path": "/spec/identityProviders", "value": []}]'
  fi

  # Patch in the htpasswd identityProvider prevent deletion of any existing identityProviders like ldap
  #  We can have multiple identityProvdiers enabled aslong as their 'name' value is unique
  oc patch oauth cluster --type json -p '[{"op": "add", "path": "/spec/identityProviders/-", "value": '"$OAUTH_PATCH_TEXT"'}]'

  export OPENSHIFT_TESTUSER_NAME=admin
  export OPENSHIFT_TESTUSER_PASS=admin
fi

if ! [ -z "${SKIP_KFDEF_INSTALL}" ]; then
  ## SKIP_KFDEF_INSTALL is useful in an instance where the 
  ## operator install comes with an init container to handle
  ## the KfDef creation
  echo "Relying on existing KfDef because SKIP_KFDEF_INSTALL was set"
else


  oc get crd odhdashboardconfigs.opendatahub.io
  result=$?
  # Apply ODH Dashboard CRDs if not applied
  # In ODH 1.4.1, the CRDs will be bundled with the ODH operator install
  if [ "$result" -ne 0 ]; then
    echo "Deploying missing ODH Dashboard CRDs"
    oc apply -k $HOME/peak/operator-tests/odh-manifests/resources/odh-dashboard/crd
  fi

  echo "Creating the following KfDef"
  cat ./${KFDEF_FILENAME} > ${ARTIFACT_DIR}/${KFDEF_FILENAME}
  oc apply -f ./${KFDEF_FILENAME}
  kfctl_result=$?
  if [ "$kfctl_result" -ne 0 ]; then
    echo "The installation failed"
    exit $kfctl_result
  fi
fi
set +x
popd
