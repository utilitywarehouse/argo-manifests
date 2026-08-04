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
  └─ step-http-call                # a cross-domain part, from shared/
  └─ step-billing-bill-run
```

A **flow** is made of **steps** — the relationship is legible in the names. In the submit
list and any alphabetical view, every `step-*` collapses into one block; flows group by
domain (`flow-billing-*`), which is how you browse. `templateRef: { name: step-http-call }`
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

## Naming the remote Job

Steps dispatch a Kubernetes Job through `step-executor-remote-namespace`. Its `job-name` parameter is the only thing that names that Job — a `metadata:` block inside `job-template` is discarded. The final name is `<job-name>-<workflow.uid[:8]>`.

The uid suffix separates runs, not steps within a run. So:

> `job-name` must be unique across every `execute-job` call one workflow run makes into the same cluster + namespace, including calls made by templates it composes.

Reuse one and the second Job creates while the first is still being torn down, and the step fails with `object is being deleted: jobs.batch "..." already exists`.

Name it after the **work**, never the target namespace — the namespace is what collides. That is the opposite of the enclosing Argo *step* name, which we do name after the namespace so the UI graph shows domain-labelled nodes. The two are independent, which is why `job-name` is passed explicitly rather than taken from the step name.

A template called many times in one run cannot use a constant. Derive it from whatever already varies per call:

```yaml
- { name: job-name, value: "http-call-{{inputs.parameters.op-name}}" }
```

Anything feeding that discriminator has to vary too — `step-grpc-call` takes an `op-name` from its caller rather than deriving one from the method it calls.

**Use exactly one parameter.** `policy/job_names.rego` proves a templated job-name by checking that
every parameter it interpolates varies across calls to the same callee. A two-part name
(`{{prefix}}-{{op-name}}`) fails that check on the half callers legitimately share, so the literal
part of the name belongs to the callee and only the discriminator is passed in.

**Length.** Kubernetes caps names at 63 characters and `exec-kube` truncates rather than failing, which would silently reintroduce collisions. Keep `job-name` to a DNS-1123 slug of **54 characters or fewer** so `-<uid8>` always fits.

`make validate` enforces all of it: `argo lint` catches a call that forgets `job-name`, and the `policy/job_names.rego` conftest policy catches duplicates, bad characters and over-long names.

## Interpolating values into `job-template`

`job-template` is a *string*. Argo substitutes `{{...}}` into it as raw text with no YAML escaping, and nothing parses the result until exec-kube hands it to the API server — so a value carrying its own syntax breaks the manifest in a remote cluster, mid-run, as `invalid job template: ... yaml: line N: did not find expected ',' or '}'`.

Two things break it, and both come from ordinary values — expr predicates like `{.name == "x"}`, GraphQL payloads:

> **Quotes.** Interpolate into a `|-` block scalar, never a quoted scalar. A `"` in the value closes a quoted one early.

```yaml
- name: SUCCESS_EXPR
  value: |-
    {{inputs.parameters.success-expr}}
```

> **Newlines.** The value has to be single-line. A `>-` scalar only folds to one line if its continuation lines are indented **the same** as the first — indent one further and YAML keeps the newline, which lands unindented inside the block scalar and ends it.

```yaml
- name: success-expr # folds to one line
  value: >-
    any(response.body.data.read_segments.segments,
    {.name == "{{inputs.parameters.segment-name}}"})
```

`policy/job_templates.rego` enforces both: it substitutes the nastiest value any caller passes to each parameter and parses the Job manifest that comes out.

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
