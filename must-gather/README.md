# must-gather for Open Data Hub

The must-gather script allows a cluster admin to collect information about various key resources and namespaces
for Open Data Hub.

## Data Collected

The must-gather script currently collects data from all the namespaces that has -
- `KfDef` instances
- `Notebook` instances
- `Inferenceservice` instances
- `DataSciencePipelinesApplication` instances

## Usage

```
oc adm must-gather --image=quay.io/opendatahub/must-gather:latest
```

#### Supported Images:

Open Data Hub supports any must-gather image in the form : 
```
quay.io/opendatahub/must-gather:<TAG>
```
- where `<TAG>` corresponds to an ODH release.
- `latest` tag corresponds to the latest ODH release

## Developer Guide

To build custom image :

```
export GATHER_IMG= <image-name>
make build-and-push-must-gather

```

To collect data for custom repositories for Open Data Hub set the following variables:

```
export ODH_NAMESPACE= <name-for-odh-namespace>