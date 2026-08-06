# Pinning container images

Executor image versions are fixed by kustomize, in the package that owns each template.

In short:

- Every image is a template **input parameter** (`inputs.parameters.[name=<x>-image]`), never a `spec.arguments` parameter — pinned by ops, not settable from the UI.
- kustomize `replacements` overwrite that parameter's default from a small local ConfigMap.
- Each package under `templates/` owns its pins (`<pkg>-image-versions` + its own replacements). No global list.
- Workflows in `billing/`, `energy-platform/`, `staging-ept/` carry no images — they reference the templates and inherit the pinned image at runtime.

## Why images are parameters, not `image:` fields

kustomize's `images:` transformer only rewrites a real `name:tag` in an `image:` field. It does not work here: most executors run as a Kubernetes Job dispatched into another namespace by `exec-kube`, and that Job is a YAML **string** (`job-template`, a `value: |` heredoc), not a real container. Inside it the image is an Argo expression:

```yaml
# step-http-call: the Job is a heredoc string, not a real container
- name: job-template
  value: |
    ...
    containers:
      - name: call
        image: {{inputs.parameters.call-http-image}}
```

`images:` cannot see a `{{...}}` expression buried in a string — only a plain YAML scalar. So the image is a template input parameter with a default: the heredoc references `{{inputs.parameters.<x>-image}}`, kustomize overwrites the parameter's `value`, and Argo substitutes it at submit time. `exec-kube` is the exception — a real `container.image` on the Argo-managed pod, replaced directly at `spec.templates.*.container.image`.

## Why input parameters, not `spec.arguments`

Argo renders `spec.arguments` parameters in the UI submit form; image tags are an ops concern, not a per-run choice, so they live in `inputs.parameters` and stay out of the form. Override is still explicit: a caller passes the parameter in its own `arguments` (explicit argument beats input default) — see [Per-environment overrides](#per-environment-overrides).

Each input parameter must carry a `value:` default — replacement runs with `create: false`, which overwrites an existing `.value` but errors if there is none.

## The replacement shape

Every replacement targets the same path:

```yaml
- spec.templates.*.inputs.parameters.[name=<x>-image].value
```

The `*` walks all templates, sets the parameter wherever it exists, and ignores templates without it — so a rule never needs to know which template holds the image. (`exec-kube` uses `spec.templates.*.container.image`.) The `select` must name the WorkflowTemplate(s) carrying the parameter; see [kustomize constraints](#kustomize-constraints).

## One ConfigMap per package

Each subdirectory of `templates/` has a `<pkg>-image-versions` ConfigMap (a `local-config` generator, stripped from output) and its own `replacements`. The top-level `templates/kustomization.yaml` has none.

A package pins the images its own templates use, wherever they are consumed — `kustomize build templates/<pkg>` resolves its own images.

**Why not one global list.** Three kustomize facts force co-location: a generated ConfigMap cannot be referenced across sibling packages (collision on aggregation); the default load-restrictor forbids reading a shared `../` file; so each package generates its own. The one cross-package image, `query-pg` (used by `energy/`, `account/`, `billing/` and `ledgers/`), is pinned in each, flagged with a comment.

## Why `templates/` is enough

`templates/` holds the reusable `step-*` / `flow-*` WorkflowTemplates — the only place executor images live and are pinned. Everything else under `argo-workflows/workflows/` is a consumer that references them by name and carries no image:

```
CronWorkflow (energy-platform)  --workflowTemplateRef-->  step-data-orchestrator-runner (templates/shared)
        business args only                                        image pinned here
                                                       renders a Job heredoc via exec-kube
                                                    remote namespace runs the pinned images
```

`templateRef` / `workflowTemplateRef` resolve from the cluster at submit time, so the image that runs is whatever the deployed template is pinned to. This is also why they deploy separately: `workflows/kustomization.yaml` bundles only `templates/`; each workflow overlay (`.../overlays/dev-merit`) is its own deploy surface referencing the templates by name.

## Bumping a version

Edit the literal in the owning package's ConfigMap; it propagates to every environment on the next apply. Use a commit SHA for a promoted version; a branch tag is fine while validating in dev. For `query-pg`, update `energy/`, `account/`, `billing/` and `ledgers/`.

### Per-environment overrides

A pin is global — a template is deployed once and referenced by name, so `staging-ept` cannot natively run a different tag than dev. When a real divergence appears, the consuming `CronWorkflow` passes the image parameter in its `arguments`, overriding the default for that workflow only:

```yaml
workflowTemplateRef: { name: step-data-orchestrator-runner }
arguments:
  parameters:
    - {
        name: orchestrator-image,
        value: registry.uw.systems/dev-enablement/data-orchestrator:<sha>,
      }
```

Add it per-workflow only when needed; do not pre-wire it.

## kustomize constraints

Confirmed against kustomize v5.6.0 — the reasons the design looks the way it does:

| Constraint | Consequence |
| --- | --- |
| `select: {kind: WorkflowTemplate}` (kind-wide) errors if any matched resource lacks the field | `select` must name the templates that carry the parameter |
| `create: true` "fixes" that by fabricating the parameter on every matched template | Never use it to go kind-wide; it pollutes unrelated templates |
| A generated ConfigMap cannot be shared across sibling packages (collision on aggregation) | Each package generates its own `<pkg>-image-versions` |
| The default load-restrictor forbids reading `../` (a shared parent env file) | Cannot hoist the literals to one file without `LoadRestrictionsNone` |
| Within a kustomization, `replacements` run before `namePrefix` | `test/` selects the unprefixed `flow-account-select` |
| `images:` transformer only sees real `image: name:tag` fields | Cannot pin `{{...}}` parameters in a heredoc |
