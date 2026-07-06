# Argo Workflows — dev environment

QE team's namespaced Argo Workflows install on `dev-merit`.

UI: https://argo-workflows.dev.merit.uw.systems

For the underlying **remote-namespace job executor** mechanics — how `executor-remote-namespace`
dispatches Jobs to a target cluster/namespace, CA-cert and `cluster-servers` registration, and
the template parameters/outputs — see [../exp-1-merit/README.md](../exp-1-merit/README.md). It's
the same design. This doc covers dev-merit onboarding via the shared **include bundle** and the
**data-orchestrator** identity.

## Onboarding a target namespace

Two sides: the target namespace opts in (in `kubernetes-manifests`, applied by kube-applier),
and the QE side (this env) stores that namespace's token.

### 1. Target namespace — include the bundle

Add one line to the namespace's `kustomization.yaml`:

```yaml
resources:
  - github.com/utilitywarehouse/argo-manifests//argo-workflows/system/namespaced/workflow/environments/dev?ref=main
```

The bundle ([`system/namespaced/workflow`](../../system/namespaced/workflow)) composes two
building blocks and applies them into the namespace:

- **`modules/job-executor`** — the `argo-workflow-job-executor` SA + Role + RoleBinding + a
  `kubernetes.io/service-account-token` Secret. exec-kube authenticates with this token to
  create / poll / tear down the run Job in the namespace.
- **`modules/data-orchestrator/overlays/dev`** — the `data-orchestrator` SA, annotated with the
  vault AWS role `qe-dev-data-orchestrator-rw` (S3 rw + `rds-db:connect`). This is the identity
  the data-orchestrator Job pod runs as.

The bundle is **environment-specific**: `environments/dev` binds the dev/qe role. A prod cluster
would include `environments/prod` (same `job-executor`, prod role on the data-orchestrator SA).

### 2. Target namespace — data-orchestrator prerequisites

The `data-orchestrator` SA only yields working AWS credentials where the namespace already has
the vault → AWS **sidecar-injection** patterns (kyverno `vault-sidecar-aws`). The runner stamps
the Job pod with `uw.systems/kyverno-inject-sidecar-request: vault-sidecar-aws`; combined with the
SA's `vault.uw.systems/aws-role`, that injects AWS creds used for **S3** and **RDS IAM auth** — no
AWS keys are stored in the namespace.

The team also provides the **adapter's source-DB secret** in their own namespace (e.g. a
`POSTGRES_DSN` for the system being exported). That secret is the team's own and is referenced by
the per-system CronWorkflow's `adapter-secret` parameter — the platform never distributes it.

### 3. Environment - Store the SA token

Harvest the (non-expiring) job-executor token and add it to
[`secrets/job-executor-tokens.env`](secrets/job-executor-tokens.env):

```bash
kubectl --context dev-merit -n <target-namespace> \
  get secret argo-workflow-job-executor-token \
  -o jsonpath='{.data.token}' | base64 -d
```

```dotenv
# pattern: <cluster-name>-<namespace>=<token>
dev-merit-<target-namespace>=<token>
```

Notes:

- The token comes from a legacy `kubernetes.io/service-account-token` Secret, so it is
  **non-expiring** (decode it and you'll see no `exp` claim). That's why we store it statically here.
- Can't read the Secret in a namespace? Either get added to that namespace's admin RoleBinding
  (`<team>-admin`, ClusterRole `admin`), or have the namespace owner harvest it. `kubectl create
token <sa>` also works but issues an **expiring** token — unsuitable for this static file unless
  the cluster grants a long-enough duration.
- The dev-merit CA cert (`secrets/dev-merit-ca.crt`) and API server
  (`cluster-servers: dev-merit=…`) are already registered in `kustomization.yaml`. Onboarding a new
  **cluster** (not just a namespace) additionally needs those — see the exp-1-merit README steps 2–4.
