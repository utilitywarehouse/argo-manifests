# Naming workflow templates

Everything under `templates/` is a `WorkflowTemplate`, and so are the entrypoints in
`billing/`, `energy-platform/`, `staging-ept/`. The `kind` never tells you whether a
thing is a job a human launches or a part another workflow calls. The name — reinforced by
labels and annotations — has to.

In short:

- **`flow-<domain>-<thing>`** — a workflow a human launches (a product, an entrypoint).
- **`step-<domain>-<thing>`** — a building block, referenced by others via `templateRef`.
- Cross-domain steps under `shared/` drop the domain: `step-executor-remote-namespace`.
- Every template carries `app.kubernetes.io/component: flow | step`, an `invocation` label,
  a UI `description`, and ownership labels — for filtering and search, not just the name.
- Filenames stay short and descriptive (`await-segment-state.yaml`); the prefix lives on
  `metadata.name`, not the file.

## The problem

Argo has no way to hide a `WorkflowTemplate` from the UI. Open **Submit new workflow** and
every template is offered — the launchable jobs and the internal building blocks side by
side, nothing in the list to tell them apart. A human picking something to run can't see
which ones are meant for them, and submitting a building block on its own is usually
meaningless or wrong.

We can't remove them from selection, so the distinction has to travel in each template's
own metadata, as loudly as possible: the **name** makes it literal at a glance, and
**labels and annotations** reinforce it and power search and filtering when viewing
workflows.

## The scheme

The prefix is a **noun that names the thing's role in composition**, so it sits in front of
a `domain-action` name without fighting its verb:

```
flow-billing-generate-bill        # the whole: launched from the UI
  └─ step-billing-produce-fwf      # a part it assembles
  └─ step-billing-bill-run
       └─ step-billing-await-segment-state
            └─ step-billing-graphql-call
```

A **flow** is made of **steps** — the relationship is legible in the names. In the submit
list and any alphabetical view, every `step-*` collapses into one block; flows group by
domain (`flow-billing-*`), which is how you browse. `templateRef: { name: step-billing-graphql-call }`
also tells the author "this is a part, not an entrypoint" right where they're reading it.

Names are DNS-1123 (`[a-z0-9-]` only — no `.`, `/`, `_`, no case), which is why the marker
is a hyphen prefix and not a separator or suffix.

## flow vs step: classify by primary intent, not capability

Every `WorkflowTemplate` is submittable — you can always launch a `step` by hand to
smoke-test it. That capability does **not** make it a `flow`.

- **flow** = a job someone deliberately opens the UI to run.
- **step** = a building block, *even if it also runs fine standalone*.

The dual-use ones (`step-billing-bill-run`, `step-account-resolve-account`,
`step-energy-assert-bills-processed`, `step-healthcheck-namespace`) are steps: their reason
to exist is to be called. Running one directly to check it is fine and expected.

## Labels and annotations

Each template carries a consistent metadata block. None of it hides a template from the
submit list — Argo can't — but together it makes intent obvious and makes templates
searchable and filterable when viewing workflows:

| key | kind | values | purpose |
| --- | --- | --- | --- |
| `app.kubernetes.io/component` | label | `flow` \| `step` | machine-readable mirror of the name prefix; the "is this launchable" filter |
| `workflows.argoproj.io/invocation` | label | `standalone` \| `reference-only` | whether it *can* be launched at all (a different axis — see below) |
| `workflows.argoproj.io/description` | annotation | free text | rendered in the UI; pure steps lead with **"Do NOT submit from the UI"** |
| `workflows.argoproj.io/creator` | label | team (`billing`, `qe`, …) | ownership; filter and search by team |
| `data.uw.systems/system` | label | owning system | filter by system |
| `data.uw.systems/capability` | label | capability (e.g. `bill-run`) | narrows to a capability where relevant |

`component` and `invocation` are **different axes**: `component` is *what the thing is*
(product vs building block), `invocation` is *whether it can be launched*. A template can
legitimately be `invocation: standalone` **and** `component: step` — the four dual-use steps
above are exactly that. Don't collapse them; they answer different questions.

## Adding a new template

1. Decide: does a human launch it? → `flow-`. Is it called by other workflows? → `step-`.
   When both, it's a `step`.
2. Name it `<marker>-<domain>-<thing>`. Omit `<domain>` only for cross-domain `shared/`
   steps.
3. Copy the metadata block: set `app.kubernetes.io/component` and
   `workflows.argoproj.io/invocation`, write a `description`, and set the ownership labels
   (`creator`, `system`, `capability`). For a step that must never be run alone
   (`invocation: reference-only`), lead the description with "Do NOT submit from the UI";
   for a standalone-capable step, describe how it's normally used instead.
4. Reference it by its full name from callers (`templateRef.name`) and from any kustomize
   `replacements` `select: { name: ... }`. Keep the filename short and descriptive; list it
   in the package `kustomization.yaml` by that filename.
