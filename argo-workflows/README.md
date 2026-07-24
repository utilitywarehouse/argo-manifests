# Argo Workflows - The workflow engine for Kubernetes

### Layout

- **system/cluster**: Cluster-scoped manifests. Owned by system and qe teams.
- **system/namespaced**: Namespaced manifests. Owned by system and qe teams.
- **workflows/**: Entrypoint `WorkflowTemplate` definitions to be referenced by `Workflow`s submitted via Argo UI, this is in line with our [workflow restriction policy](https://argo-workflows.readthedocs.io/en/latest/workflow-restrictions/).
- **workflows/templates/shared**: Shared execution units and reusable logic that all teams should use (i.e. common steps, notifications, utilities). Owned by qe.
- **workflows/templates/<team>**: Execution units and reusable logic specific to the products, services, and systems owned by that team. Owned by the respective team.

### System

- `make get-upstream`: gets the upstream manifests in a single file and splits it
  in to cluster and namespaced resources. when updating please manually check for
  any new resource type added to upstream.

### Documentation

- [Installation Options](https://argo-workflows.readthedocs.io/en/latest/installation/#installation-options)
- [GitHub Project](https://github.com/argoproj/argo-workflows/tree/main/manifests)

### Provisional ADRs

- We are keeping to namespace install for POC
- Install via project releases as the [helm chart](https://github.com/argoproj/argo-helm) is community maintained. This was the approach taken for [argocd](../argocd/) also
