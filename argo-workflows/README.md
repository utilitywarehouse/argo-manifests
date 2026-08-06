# Argo Workflows - The workflow engine for Kubernetes

### Layout

- **system/cluster**: Cluster-scoped manifests. Owned by system and qe teams.
- **system/namespaced**: Namespaced manifests. Owned by system and qe teams.
- **workflows/**: Entrypoint `WorkflowTemplate` definitions to be referenced by `Workflow`s submitted via Argo UI, this is in line with our [workflow restriction policy](https://argo-workflows.readthedocs.io/en/latest/workflow-restrictions/).
- **workflows/templates/shared**: Shared execution units and reusable logic that all teams should use (i.e. common steps, notifications, utilities). Owned by qe.
- **workflows/templates/<team>**: Execution units and reusable logic specific to the products, services, and systems owned by that team. Owned by the respective team.

### Validating

`mise install` once for the toolchain (kustomize, argo, conftest, yq, prettier), then:

```sh
make validate   # build + lint + policy, every package
make fmt        # prettier --write
make tools      # check the toolchain, and that the argo pin matches the cluster
```

Every package — `workflows/templates/<team>`, `workflows/<product>`, `environments/<env>` — has a Makefile including [conventions.mk](conventions.mk) and so answers the same targets (`build`, `lint`, `check`, `fmt`, `validate`, `clean`). Run them per package with `make -C <package> <target>`.

The conventions live here rather than at the repo root because they are argo-specific (`argo lint`, the conftest policies, the argo version pin). The root Makefile just delegates, so the same targets work from either level.

`lint` and `check` only do work in `environments/`: that is where kustomize applies the `namespace:` transformer, without which `templateRef`s cannot resolve. Everything else renders and is validated there.

Policies live in [policy/](policy/) and run under conftest. Each enforces a convention that `argo lint` cannot see, and each is written up in [docs/](docs/), the policy is where the rule is checked, the doc is where it is explained. Add one and add its doc.

Adding a package means a `kustomization.yaml` and a Makefile; the root Makefile discovers it by that Makefile, so nothing has to be registered:

```makefile
include ../../../conventions.mk

PKG=templates-<team>
LINTABLE=no          # only environments/ can resolve templateRefs
```

### System

- `make get-upstream`: gets the upstream manifests in a single file and splits it in to cluster and namespaced resources. when updating please manually check for any new resource type added to upstream. Run it from `system/`, and bump `argo` in [mise.toml](../mise.toml) to match.

### Documentation

- [Installation Options](https://argo-workflows.readthedocs.io/en/latest/installation/#installation-options)
- [GitHub Project](https://github.com/argoproj/argo-workflows/tree/main/manifests)

### Provisional ADRs

- We are keeping to namespace install for POC
- Install via project releases as the [helm chart](https://github.com/argoproj/argo-helm) is community maintained. This was the approach taken for [argocd](../argocd/) also
